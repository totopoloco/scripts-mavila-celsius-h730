#!/usr/bin/env bash
#
# verify-nouveau.sh
#
# Read-only health check for life after the proprietary driver: is nouveau
# really driving the Quadro K2100M, and is the rest of the graphics stack
# behaving the way this machine needs? Companion to switch-to-nouveau.sh. Run
# it after that script and the reboot, again during the Wayland trial period,
# and once more after do-release-upgrade.
#
# On this machine the Intel iGPU is the display GPU (the only VGA-class device;
# the K2100M is a 3D controller) and the NVIDIA card is an offload target. A
# healthy nouveau setup therefore looks like this:
#   1. Session      Wayland (GDM's default once nvidia-drm stops vetoing it)
#   2. GPU power    the K2100M runtime-suspends when idle (with the proprietary
#                   driver it stayed "active" around the clock)
#   3. Driver       nouveau is the kernel driver bound to the K2100M
#   4. Desktop      GL renders on the Intel iGPU
#   5. Offload      DRI_PRIME=1 renders on the NVIDIA card through nouveau,
#                   not through llvmpipe software rendering
#   6. GPU power    after that wake-up the card goes back to sleep
#   7. Kernel log   nouveau logged nothing that looks like an error this boot
#
# Every check prints a verdict: "ok", "!" (worth a look, not necessarily wrong,
# e.g. an X11 session you picked on purpose) or "x" (broken). Exit status is 1
# if any check failed, otherwise 0.
#
# Changes nothing and needs no sudo. Run it as your normal user from a terminal
# inside the desktop session, because it needs XDG_SESSION_TYPE and a DISPLAY.
#
# Step 2 deliberately comes before anything else touches the card: lspci and
# every GL client wake it, after which it reads "active" for the driver's
# autosuspend delay and would hide the answer.
#
# Usage:
#   ./verify-nouveau.sh
#   ./verify-nouveau.sh -h | --help
#
set -uo pipefail

PCI_DEVICES=/sys/bus/pci/devices
SUSPEND_WAIT=20     # seconds to wait for the card to runtime-suspend

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# --- helpers ----------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'
  c_dim=$'\e[2m';  c_rst=$'\e[0m'
else
  c_red=""; c_grn=""; c_ylw=""; c_blu=""; c_dim=""; c_rst=""
fi

N_OK=0; N_WARN=0; N_FAIL=0

log()  { printf '\n%s==>%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { N_OK=$((N_OK + 1));     printf '%s  ok%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { N_WARN=$((N_WARN + 1)); printf '%s  ! %s %s\n' "$c_ylw" "$c_rst" "$*"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '%s  x %s %s\n' "$c_red" "$c_rst" "$*"; }
note() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_rst"; }   # advice under a verdict
show() { sed 's/^/    /'; }                                  # indent raw evidence

# --- find the NVIDIA GPU ----------------------------------------------------
# Straight from sysfs: reading these attributes doesn't wake the card, whereas
# lspci reads PCI config space and does.

GPU_DEV=""
for d in "$PCI_DEVICES"/*; do
  read -r vendor 2>/dev/null < "$d/vendor" || continue
  read -r class  2>/dev/null < "$d/class"  || continue
  if [[ "$vendor" == 0x10de && "$class" == 0x03* ]]; then
    GPU_DEV="$d"
    break
  fi
done
if [[ -z "$GPU_DEV" ]]; then
  echo "No NVIDIA GPU found on the PCI bus - nothing to verify." >&2
  exit 1
fi
GPU_ADDR="${GPU_DEV##*/}"

# wait_suspended <seconds>: poll the card's runtime-PM state until it reads
# "suspended" or the time is up. Leaves the last reading in RPM_STATE and the
# seconds waited in RPM_WAITED. Returns 0 only if the card is suspended.
wait_suspended() {
  local limit="$1"
  RPM_WAITED=0
  while :; do
    RPM_STATE="$(cat "$GPU_DEV/power/runtime_status" 2>/dev/null || echo unknown)"
    [[ "$RPM_STATE" == suspended ]] && return 0
    (( RPM_WAITED == 0 )) && note "reads '$RPM_STATE', waiting up to ${limit}s for it to suspend..."
    (( RPM_WAITED >= limit )) && return 1
    sleep 1
    RPM_WAITED=$((RPM_WAITED + 1))
  done
}

# check_power <context>: wait for the card to suspend, then give the verdict.
# Returns 0 if it did.
check_power() {
  local ctx="$1" ctl
  if wait_suspended "$SUSPEND_WAIT"; then
    if (( RPM_WAITED == 0 )); then
      ok "card is suspended ($ctx)"
    else
      ok "card suspended after ${RPM_WAITED}s ($ctx)"
    fi
    return 0
  fi
  if [[ "$RPM_STATE" == error ]]; then
    fail "runtime PM is in an error state ($ctx)"
  else
    warn "card still '$RPM_STATE' after ${SUSPEND_WAIT}s ($ctx)"
  fi
  ctl="$(cat "$GPU_DEV/power/control" 2>/dev/null || echo unknown)"
  if [[ "$ctl" == auto ]]; then
    note "power/control is 'auto', so runtime PM is allowed: the driver or a process keeps the card busy."
  else
    note "power/control is '$ctl': runtime PM is switched off for this card (it needs 'auto')."
  fi
  note "Who has the card open:  fuser -v /dev/dri/card* /dev/dri/renderD*"
  return 1
}

# gl_renderer [VAR=value ...]: print glxinfo's "OpenGL renderer string" under
# the given environment, or nothing if glxinfo is missing or has no display.
gl_renderer() {
  command -v glxinfo >/dev/null 2>&1 || return 0
  timeout 30 env "$@" glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p'
}

# --- 1. session -------------------------------------------------------------

log "1. Session type"
session="${XDG_SESSION_TYPE:-unset}"
case "$session" in
  wayland)
    ok "Wayland session"
    ;;
  x11)
    warn "X11 session"
    note "Expected only if you picked 'Ubuntu on Xorg' at the login screen, or if"
    note "WaylandEnable=false is still set in /etc/gdm3/custom.conf."
    note "Ubuntu 26.04 has no Xorg session, so Wayland is the one to trial."
    ;;
  *)
    warn "session type is '$session' - run this from a terminal inside the desktop session"
    ;;
esac

# --- 2. power at rest (before anything wakes the card) ----------------------

log "2. K2100M power state, idle"
POWER_IDLE_OK=0
check_power "idle, before anything woke it" && POWER_IDLE_OK=1

# --- 3. driver --------------------------------------------------------------

log "3. Kernel driver bound to the K2100M"
lspci -k -d ::03xx 2>/dev/null | show
drv=""
[[ -L "$GPU_DEV/driver" ]] && drv="$(basename "$(readlink "$GPU_DEV/driver")")"
case "$drv" in
  nouveau)
    ok "nouveau is driving $GPU_ADDR"
    ;;
  nvidia)
    fail "$GPU_ADDR is still on the proprietary nvidia driver"
    note "Has switch-to-nouveau.sh run, and has the machine rebooted since?"
    note "Check the loaded modules with:  lsmod | grep '^nvidia'"
    ;;
  "")
    fail "no kernel driver is bound to $GPU_ADDR"
    ;;
  *)
    fail "$GPU_ADDR is bound to '$drv', not nouveau"
    ;;
esac

# --- 4. desktop renderer ----------------------------------------------------

log "4. Desktop GL renderer (glxinfo -B)"
renderer="$(gl_renderer)"
case "$renderer" in
  "")
    warn "glxinfo gave no answer - is mesa-utils installed and DISPLAY set?"
    ;;
  *llvmpipe*|*softpipe*|*swrast*)
    fail "the desktop is on software rendering: $renderer"
    ;;
  *[Ii]ntel*)
    ok "desktop renders on the Intel iGPU: $renderer"
    ;;
  *)
    warn "desktop renders on '$renderer', not the Intel iGPU"
    note "The Intel iGPU is this machine's only VGA-class device, so it should be the display GPU."
    ;;
esac

# --- 5. offload renderer ----------------------------------------------------

log "5. Offload GL renderer (DRI_PRIME=1 glxinfo -B)"
renderer="$(gl_renderer DRI_PRIME=1)"
case "$renderer" in
  "")
    warn "glxinfo gave no answer - is mesa-utils installed and DISPLAY set?"
    ;;
  *llvmpipe*|*softpipe*|*swrast*)
    fail "DRI_PRIME=1 fell back to software rendering: $renderer"
    note "Mesa found no driver for the NVIDIA card (expected while the proprietary driver is loaded)."
    ;;
  *[Ii]ntel*)
    warn "DRI_PRIME=1 still picked the Intel iGPU: $renderer"
    note "Offload is not selecting the NVIDIA card."
    ;;
  *)
    ok "offload renders on the NVIDIA card: $renderer"
    ;;
esac

# --- 6. power after the offload test ----------------------------------------

log "6. K2100M power state after the offload test"
if (( POWER_IDLE_OK )); then
  check_power "back asleep after being woken"
else
  note "skipped: the card never suspended at idle in step 2, so this can't tell you more."
fi

# --- 7. kernel log ----------------------------------------------------------

log "7. nouveau in this boot's kernel log"
klog="$(journalctl -k -b -o short-monotonic --no-hostname --no-pager 2>&1)"
if grep -q 'not seeing messages' <<<"$klog"; then
  warn "can't read the kernel journal - join the adm group, or run: sudo journalctl -k -b | grep -i nouveau"
else
  nvlog="$(grep -i nouveau <<<"$klog")"
  if [[ -z "$nvlog" ]]; then
    warn "nouveau logged nothing this boot - the module never loaded"
  else
    n_all="$(wc -l <<<"$nvlog")"
    bad="$(grep -iE 'fail|error|fault|timeout|timed out|unable|invalid|denied|warning|oops|\<bug\>' <<<"$nvlog")"
    if [[ -n "$bad" ]]; then
      warn "$(wc -l <<<"$bad") of $n_all nouveau messages look like trouble:"
      head -10 <<<"$bad" | show
    else
      ok "$n_all nouveau messages, none look like errors"
      note "Full log:  journalctl -k -b | grep -i nouveau"
    fi
  fi
fi

# --- summary ----------------------------------------------------------------

log "Summary"
printf '    %d ok, %d warning(s), %d failure(s)\n' "$N_OK" "$N_WARN" "$N_FAIL"
if   (( N_FAIL > 0 )); then echo "    ${c_red}Something is wrong - read the x lines above.${c_rst}"
elif (( N_WARN > 0 )); then echo "    ${c_ylw}Working, but read the ! lines above.${c_rst}"
else                        echo "    ${c_grn}All good.${c_rst}"
fi
exit $(( N_FAIL > 0 ? 1 : 0 ))
