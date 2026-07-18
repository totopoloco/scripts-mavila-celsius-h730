#!/usr/bin/env bash
#
# fix-mic-input.sh
#
# Diagnoses (and can fix) GNOME Settings > Sound > Input showing no
# microphone on this machine, even though the built-in mic is physically
# fine.
#
# Root cause (confirmed 2026-07-18): the internal codec (Realtek ALC282 on
# the Intel PCH HDA controller) is seen fine by the kernel/ALSA, but
# WirePlumber sometimes fails to bring up (or hold up) the matching
# `alsa_input.pci-*.analog-stereo` PipeWire node -- usually after a "Device
# or resource busy" race at login/resume. The node then either never
# appears or flaps in and out of `pactl list sources`, so pipewire-pulse
# logs repeated "source not ready" errors and GNOME Settings has nothing to
# list. Kernel/ALSA and the hardware mixer are unaffected -- this is a stuck
# PipeWire/WirePlumber user session, not a driver or hardware fault, so a
# full reboot is NOT required. Restarting the three user-level audio
# services is enough.
#
# This only touches user-level `systemctl --user` services (pipewire,
# pipewire-pulse, wireplumber). No sudo, no persistent config changes.
#
# Usage:
#   ./fix-mic-input.sh              # diagnose only, print a verdict
#   ./fix-mic-input.sh --fix        # diagnose, and restart the audio
#                                    # services if the bug is found
#   ./fix-mic-input.sh --fix -n     # same, but just print what would run
#   ./fix-mic-input.sh --help
#
# Exit status: 0 if the mic looks healthy (or --fix resolved it), 1 if a
# problem remains, 2 on a usage error.
#
set -uo pipefail

DO_FIX=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    -f|--fix)     DO_FIX=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# --- helpers ------------------------------------------------------------

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_rst=$'\e[0m'

log()  { echo "${c_blu}==>${c_rst} $*"; }
ok()   { echo "${c_grn}  ok${c_rst} $*"; }
warn() { echo "${c_ylw}  ! ${c_rst} $*"; }
err()  { echo "${c_red}  x ${c_rst} $*" >&2; }

# Run a command, or just print it under --dry-run. No sudo -- everything
# this script touches is a user-session systemd unit.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "   ${c_ylw}[dry-run]${c_rst} $*"
  else
    "$@"
  fi
}

# Internal (PCH) codec's ALSA card number -- not hardcoded, since USB/dock
# devices attached at boot can shift card enumeration order.
find_internal_card() {
  awk -F'[][]' '$2 ~ /^PCH/ { gsub(/ /, "", $1); print $1; exit }' /proc/asound/cards 2>/dev/null
}

# Does a PCI-based (i.e. internal, not USB dock) capture source currently
# exist in PipeWire? The internal codec is the only PCI card on this
# machine with an input at all (the HDMI card is output-only).
internal_mic_source_present() {
  pactl list sources short 2>/dev/null | awk '$2 ~ /^alsa_input\.pci-/ { f=1 } END { exit !f }'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE=""
LOG_TEE_PID=""

# Only a real --fix run (not dry-run, not plain diagnosis) leaves an audit
# trail, matching this repo's other mutating scripts.
if [[ $DO_FIX -eq 1 && $DRY_RUN -eq 0 ]]; then
  c_red=""; c_grn=""; c_ylw=""; c_blu=""; c_rst=""
  LOG_FILE="${SCRIPT_DIR}/fix-mic-input-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee "$LOG_FILE") 2>&1
  LOG_TEE_PID=$!
  trap 'exec >&- 2>&-; [[ -n "${LOG_TEE_PID:-}" ]] && wait "${LOG_TEE_PID}" 2>/dev/null' EXIT
  log "Logging this run to: ${LOG_FILE}"
fi

problem_found=0
need_restart=0
capture_muted=0

# --- 1. kernel / ALSA -----------------------------------------------------

log "Checking whether the kernel/ALSA sees the built-in mic..."
card_num="$(find_internal_card)"
if [[ -n "$card_num" ]]; then
  card_line=$(grep -E "^ ${card_num} \[" /proc/asound/cards)
  ok "Found internal audio card ${card_num}: ${card_line#* - }"
  if arecord -l 2>/dev/null | grep -q "^card ${card_num}:"; then
    ok "ALSA reports a capture device on card ${card_num}."
  else
    err "ALSA does NOT report a capture device on card ${card_num}."
    err "That points at a driver/hardware problem, not the PipeWire bug -- a reboot may genuinely be needed here."
    problem_found=1
  fi
else
  warn "Could not find the internal 'PCH' card in /proc/asound/cards:"
  sed 's/^/      /' /proc/asound/cards 2>/dev/null || echo "      (no sound cards at all!)"
  problem_found=1
fi
echo

# --- 2. user audio services ------------------------------------------------

log "Checking pipewire/pipewire-pulse/wireplumber user services..."
for svc in pipewire pipewire-pulse wireplumber; do
  state=$(systemctl --user is-active "$svc" 2>/dev/null)
  [[ -z "$state" ]] && state="unknown"
  if [[ "$state" == "active" ]]; then
    ok "${svc}.service is active"
  else
    err "${svc}.service is ${state} (expected: active)"
    problem_found=1
    need_restart=1
  fi
done
started=$(systemctl --user show pipewire.service --property=ActiveEnterTimestamp --value 2>/dev/null || true)
[[ -n "$started" ]] && log "pipewire.service has been running since: ${started}"
echo

# --- 3. PipeWire source enumeration, sampled to catch flapping -------------

SAMPLES=3
log "Sampling PipeWire sources ${SAMPLES}x, 1s apart (a flapping node looks fine on a single check)..."
present_count=0
for i in $(seq 1 "$SAMPLES"); do
  internal_mic_source_present && present_count=$((present_count + 1))
  [[ $i -lt $SAMPLES ]] && sleep 1
done

if [[ $present_count -eq $SAMPLES ]]; then
  mic_source_name=$(pactl list sources short 2>/dev/null | awk '$2 ~ /^alsa_input\.pci-/ { print $2; exit }')
  ok "Internal mic source present in all ${SAMPLES}/${SAMPLES} checks: ${mic_source_name}"
elif [[ $present_count -eq 0 ]]; then
  err "Internal mic source absent in all ${SAMPLES}/${SAMPLES} checks -- this is the known bug."
  problem_found=1
  need_restart=1
else
  warn "Internal mic source FLAPPED: present in only ${present_count}/${SAMPLES} checks -- this is the known bug."
  problem_found=1
  need_restart=1
fi
echo

# --- 4. corroborating evidence: pipewire-pulse journal ---------------------

not_ready=$(journalctl --user -u pipewire-pulse --since "-15 min" --no-pager 2>/dev/null \
  | grep -c "source not ready" || true)
if [[ "${not_ready:-0}" -gt 0 ]]; then
  warn "pipewire-pulse logged ${not_ready} \"source not ready\" error(s) in the last 15 minutes."
fi
echo

# --- 5. hardware mixer sanity -----------------------------------------------

if [[ -n "$card_num" ]]; then
  log "Checking the hardware Capture switch on card ${card_num}..."
  capture_line=$(amixer -c "$card_num" sget Capture 2>/dev/null || true)
  if grep -q '\[off\]' <<<"$capture_line"; then
    err "Capture is MUTED at the hardware mixer level."
    err "  Fix with: amixer -c ${card_num} sset Capture unmute"
    problem_found=1
    capture_muted=1
  else
    ok "Capture is unmuted."
  fi
  boost_line=$(amixer -c "$card_num" sget 'Internal Mic Boost' 2>/dev/null || true)
  boost_pct=$(grep -oP '\d+(?=%)' <<<"$boost_line" | head -1)
  if [[ "${boost_pct:-}" == "0" ]]; then
    warn "Internal Mic Boost is at 0% -- mic will work but may sound quiet."
    warn "  Raise it with: alsamixer -c ${card_num}   (or Settings > Sound > Input)"
  fi
  echo
fi

# --- verdict / fix -----------------------------------------------------------

if [[ $problem_found -eq 0 ]]; then
  ok "Everything looks healthy -- no sign of the stuck-mic bug."
  exit 0
fi

log "Problem found: input devices are likely missing (or will be) in GNOME Settings."
final_exit=1

if [[ $need_restart -eq 1 ]]; then
  if [[ $DO_FIX -ne 1 ]]; then
    warn "Re-run with --fix to restart the audio services automatically (add -n to preview first)."
  else
    log "Restarting the user audio stack (wireplumber, pipewire, pipewire-pulse)..."
    streams=$(pactl list sink-inputs 2>/dev/null | awk -F'"' '/application\.name/ { print $2 }')
    if [[ -n "$streams" ]]; then
      warn "This will briefly interrupt active playback in: $(echo "$streams" | paste -sd, -)"
    fi
    run systemctl --user restart wireplumber pipewire pipewire-pulse

    if [[ $DRY_RUN -eq 1 ]]; then
      log "Dry run complete. Re-run with --fix (no -n) to actually restart the services."
    else
      log "Re-checking..."
      sleep 2
      if internal_mic_source_present; then
        mic_source_name=$(pactl list sources short 2>/dev/null | awk '$2 ~ /^alsa_input\.pci-/ { print $2; exit }')
        ok "Internal mic source is back: ${mic_source_name}"
        log "Open GNOME Settings > Sound > Input to confirm it lists the microphone."
        [[ $capture_muted -eq 0 ]] && final_exit=0
      else
        err "Still not showing up after restarting the audio services."
        err "That's past what a service restart fixes -- try a full reboot next, and if it"
        err "keeps recurring, dig further with:"
        err "  arecord -l ; pactl list sources short ; journalctl --user -u pipewire-pulse -b"
      fi
    fi
  fi
elif [[ $capture_muted -eq 1 ]]; then
  err "Not something a service restart fixes -- see the mixer suggestion above."
fi

[[ -n "$LOG_FILE" ]] && log "Full log of this run: ${LOG_FILE}"
exit $final_exit
