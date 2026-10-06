#!/usr/bin/env bash
#
# nouveau-video-firmware.sh
#
# Installs the video-decode firmware that nouveau asks for on this machine's
# Quadro K2100M (GK106, chipset NVE6) and can't find. Without it, every program
# that probes the card's video engine (GStreamer's plugin scan at login,
# vainfo, ...) leaves these four lines in the kernel log:
#   Direct firmware load for nouveau/nve6_fuc084 failed with error -2
#   Direct firmware load for nouveau/nve6_fuc084d failed with error -2
#   msvld: unable to load firmware data
#   msvld: init failed, -19
# They are one missing file: the kernel only asks for the ...d variant after
# nve6_fuc084 isn't there.
#
# No package ships this firmware, and none will: it is NVIDIA's Kepler (VP5)
# video microcode, and NVIDIA's license forbids redistributing it. nouveau's
# documented fix is to cut it out of an old NVIDIA driver yourself. This script
# does that:
#   1. Downloads NVIDIA-Linux-x86_64-340.108.run (70 MB) from
#      download.nvidia.com into a temporary directory and checks its SHA-256.
#   2. Unpacks only kernel/nv-kernel.o from it (tail | xz | tar). None of
#      NVIDIA's code runs, not even the installer's shell header.
#   3. Cuts the three blobs NVE6 uses out of nv-kernel.o and checks each one's
#      SHA-256.
#   4. Installs them into /usr/lib/firmware/nouveau/, plus the names the kernel
#      asks for (nve6_fuc084/085/086) as symlinks to them. This is the only
#      step that needs sudo, and it never overwrites a file it didn't put there.
#   5. Wakes the card once through VA-API (vainfo) and checks that the kernel
#      now loads the firmware.
# Steps 1-3 run as you; the temporary directory is deleted at the end. No
# reboot or initramfs rebuild is needed: nouveau reads the firmware the next
# time something opens the video engine.
#
# Why 340.108 and not 470.256.02, the driver this machine ran before nouveau:
# the offsets and lengths come from envytools' extract_firmware.py
# (github.com/envytools/firmware, commit a0b9f9b), which only understands
# driver layouts 319.17 to 340.108. Running it on this installer produces
# byte-identical files.
#
# Side effect: Mesa's VA-API driver now offers H.264, MPEG-2 and VC-1 decoding
# on the K2100M, so anything that probes the card through VA-API probes deeper.
# On this machine nothing does: /etc/environment.d/90-libva-i965.conf pins
# LIBVA_DRIVER_NAME=i965 for every user session, the GDM greeter included. That
# file was set up by hand on 2026-10-06; this script doesn't manage it and
# --undo leaves it alone. Without it, the greeter (its own user, gdm-greeter)
# rescans GStreamer's plugins at every boot and probes the card, and with this
# firmware present Mesa answers with 11 harmless "gr: TRAP ... RT_HEIGHT_OVERRUN"
# reports instead of 3. verify-nouveau.sh doesn't flag those either way.
#
# A real --apply or --undo is logged to
# nouveau-video-firmware-YYYYmmdd-HHMMSS.log next to this script.
#
# Usage:
#   ./nouveau-video-firmware.sh            # steps 1-5 (same as --apply)
#   ./nouveau-video-firmware.sh --dry-run  # steps 1-3, then print step 4's commands
#   ./nouveau-video-firmware.sh -n         # same as --dry-run
#   ./nouveau-video-firmware.sh --status   # files + this boot's kernel log; no sudo, card stays asleep
#   ./nouveau-video-firmware.sh --test     # step 5 on its own (wakes the card)
#   ./nouveau-video-firmware.sh --undo     # remove exactly what --apply installed
#   ./nouveau-video-firmware.sh -h | --help
#
set -uo pipefail

DRY_RUN=0
ACTION="apply"

FW_DIR=/usr/lib/firmware/nouveau
GPU_ID=0x11fc                     # PCI device ID of the Quadro K2100M (GK106)
PCI_DEVICES=/sys/bus/pci/devices

DRIVER_RUN="NVIDIA-Linux-x86_64-340.108.run"
DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/340.108/${DRIVER_RUN}"
DRIVER_SHA256="c671d4f1b7c09bc1af079b98b447adb06d704b04f802f7045a611fa50133b71b"

# name:offset:length:sha256 of each blob inside that installer's
# kernel/nv-kernel.o.
BLOBS=(
  "nve0_bsp:0x84a340:0x11c00:f5259807bd7a3070b9c8bc47ccba0f51fad75c8200cc4d32e60613e81e137259"
  "nve0_vp:0x943e80:0xdd00:ca2e39fa08b936313f52d1b887dcff9c79013255461f16e3ab540275f67f7fe2"
  "nvc0_ppp:0x8d3c80:0x4100:7595df09ca8226f849914b24e8af6c30df2a7aca2b2842eb1647312181bb9ac0"
)

# link:target. nouveau requests nv<chipset>_fuc<engine base address>: 084 is
# msvld (bitstream decoder), 085 mspdec (video decoder), 086 msppp
# (post-processor).
LINKS=(
  "nve6_fuc084:nve0_bsp"
  "nve6_fuc085:nve0_vp"
  "nve6_fuc086:nvc0_ppp"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=""
LOG_FILE=""
LOG_TEE_PID=""
GPU_DEV=""
GPU_ADDR=""

for arg in "$@"; do
  case "$arg" in
    --apply)      ACTION="apply" ;;
    --undo)       ACTION="undo" ;;
    --status)     ACTION="status" ;;
    --test)       ACTION="test" ;;
    -n|--dry-run) DRY_RUN=1 ;;
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
  c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_rst=$'\e[0m'
else
  c_red=""; c_grn=""; c_ylw=""; c_blu=""; c_rst=""
fi

log()  { echo "${c_blu}==>${c_rst} $*"; }
ok()   { echo "${c_grn}  ok${c_rst} $*"; }
warn() { echo "${c_ylw}  ! ${c_rst} $*"; }
err()  { echo "${c_red}  x ${c_rst} $*" >&2; }
show() { sed 's/^/    /'; }                                  # indent raw evidence

# Run a privileged command, or just print it under --dry-run.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "   ${c_ylw}[dry-run]${c_rst} sudo $*"
  else
    sudo "$@"
  fi
}

# Delete the temporary directory, and flush the log's tee so the file is
# complete (bash doesn't wait for a process substitution on its own).
on_exit() {
  [[ -n "$WORK" ]] && rm -rf "$WORK"
  if [[ -n "$LOG_TEE_PID" ]]; then
    exec >&- 2>&-
    wait "$LOG_TEE_PID" 2>/dev/null
  fi
}
trap on_exit EXIT

sha256() { sha256sum < "$1" | cut -d' ' -f1; }

# blob_state <name> <sha256> / link_state <name> <target>: what is at
# $FW_DIR/<name> right now. "missing", "ours" (exactly what --apply installs)
# or "foreign" (anything else, which this script never overwrites or removes).
blob_state() {
  local p="$FW_DIR/$1"
  if [[ ! -e "$p" && ! -L "$p" ]]; then
    echo missing
  elif [[ -f "$p" && ! -L "$p" && "$(sha256 "$p")" == "$2" ]]; then
    echo ours
  else
    echo foreign
  fi
}

link_state() {
  local p="$FW_DIR/$1"
  if [[ ! -e "$p" && ! -L "$p" ]]; then
    echo missing
  elif [[ -L "$p" && "$(readlink "$p")" == "$2" ]]; then
    echo ours
  else
    echo foreign
  fi
}

# report_files: one verdict line per file; returns 0 only if all six are
# exactly what --apply installs.
report_files() {
  local entry name target sum rc=0
  for entry in "${BLOBS[@]}"; do
    IFS=: read -r name _ _ sum <<<"$entry"
    case "$(blob_state "$name" "$sum")" in
      ours)    ok "$name (SHA-256 matches)" ;;
      missing) warn "$name is missing"; rc=1 ;;
      foreign) warn "$name is not the file this script installs"; rc=1 ;;
    esac
  done
  for entry in "${LINKS[@]}"; do
    IFS=: read -r name target <<<"$entry"
    case "$(link_state "$name" "$target")" in
      ours)    ok "$name -> $target" ;;
      missing) warn "$name is missing"; rc=1 ;;
      foreign) warn "$name is not a symlink to $target"; rc=1 ;;
    esac
  done
  return $rc
}

installed() { report_files >/dev/null; }

# find_gpu: set GPU_DEV and GPU_ADDR straight from sysfs. Reading these
# attributes doesn't wake the card, whereas lspci reads PCI config space and does.
find_gpu() {
  local d vendor class
  for d in "$PCI_DEVICES"/*; do
    read -r vendor 2>/dev/null < "$d/vendor" || continue
    read -r class  2>/dev/null < "$d/class"  || continue
    if [[ "$vendor" == 0x10de && "$class" == 0x03* ]]; then
      GPU_DEV="$d"
      GPU_ADDR="${d##*/}"
      return 0
    fi
  done
  return 1
}

# check_gpu: stop unless the card this firmware is for is on the bus.
check_gpu() {
  local id drv=""
  if ! find_gpu; then
    err "No NVIDIA GPU on the PCI bus, so nothing would use this firmware."
    exit 1
  fi
  read -r id < "$GPU_DEV/device"
  if [[ "$id" != "$GPU_ID" ]]; then
    err "$GPU_ADDR is NVIDIA device $id, not the Quadro K2100M ($GPU_ID) this firmware is for."
    exit 1
  fi
  [[ -L "$GPU_DEV/driver" ]] && drv="$(basename "$(readlink "$GPU_DEV/driver")")"
  if [[ "$drv" == nouveau ]]; then
    ok "Quadro K2100M at $GPU_ADDR, driven by nouveau"
  else
    warn "Quadro K2100M at $GPU_ADDR is bound to '${drv:-nothing}', not nouveau:"
    warn "the firmware sits unused until nouveau drives the card."
  fi
}

# --- steps 1-3: fetch and cut the firmware (as you, in a temp dir) ----------

fetch_firmware() {
  local cmd skip entry name off len sum
  for cmd in curl xz tar dd sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "$cmd is required but not installed."
      exit 1
    fi
  done
  if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/nouveau-video-firmware.XXXXXX")"; then
    err "Could not create a temporary directory."
    exit 1
  fi

  log "1. Downloading ${DRIVER_RUN} (70 MB) from download.nvidia.com..."
  if ! curl -fsSL --retry 3 -o "$WORK/$DRIVER_RUN" "$DRIVER_URL"; then
    err "Download failed: $DRIVER_URL"
    exit 1
  fi
  sum="$(sha256 "$WORK/$DRIVER_RUN")"
  if [[ "$sum" != "$DRIVER_SHA256" ]]; then
    err "${DRIVER_RUN} has SHA-256 $sum, expected $DRIVER_SHA256."
    exit 1
  fi
  ok "SHA-256 matches"

  log "2. Unpacking kernel/nv-kernel.o (nothing from the installer runs)..."
  # The .run file is a shell header followed by an xz-compressed tar starting
  # at line $skip. The header unpacks itself with this same pipeline.
  skip="$(awk -F= '/^skip=/ {print $2; exit}' "$WORK/$DRIVER_RUN")"
  if [[ ! "$skip" =~ ^[0-9]+$ ]] \
     || ! tail -n +"$skip" "$WORK/$DRIVER_RUN" | xz -dc | tar -xf - -C "$WORK" ./kernel/nv-kernel.o; then
    err "Could not unpack kernel/nv-kernel.o from ${DRIVER_RUN}."
    exit 1
  fi
  ok "Unpacked"

  log "3. Cutting the NVE6 firmware out of nv-kernel.o..."
  for entry in "${BLOBS[@]}"; do
    IFS=: read -r name off len sum <<<"$entry"
    dd if="$WORK/kernel/nv-kernel.o" of="$WORK/$name" bs=64K status=none \
       iflag=skip_bytes,count_bytes skip=$((off)) count=$((len))
    if [[ "$(sha256 "$WORK/$name")" != "$sum" ]]; then
      err "$name doesn't have the expected SHA-256, so nothing gets installed."
      exit 1
    fi
    ok "$name, $((len)) bytes, SHA-256 matches"
  done
}

# --- step 4: install (sudo) -------------------------------------------------

# check_clashes: stop before downloading anything if a target name is taken by
# a file this script didn't install, so a clash changes nothing.
check_clashes() {
  local entry name target sum clash=0
  for entry in "${BLOBS[@]}"; do
    IFS=: read -r name _ _ sum <<<"$entry"
    if [[ "$(blob_state "$name" "$sum")" == foreign ]]; then
      err "$FW_DIR/$name exists but is not the file this script installs."
      clash=1
    fi
  done
  for entry in "${LINKS[@]}"; do
    IFS=: read -r name target <<<"$entry"
    if [[ "$(link_state "$name" "$target")" == foreign ]]; then
      err "$FW_DIR/$name exists but is not a symlink to $target."
      clash=1
    fi
  done
  if (( clash )); then
    err "Not overwriting files this script didn't install. Move them aside and run it again."
    exit 1
  fi
}

install_firmware() {
  local entry name target sum
  log "4. Installing into ${FW_DIR}/..."
  [[ -d "$FW_DIR" ]] || run install -d -m 0755 "$FW_DIR"
  for entry in "${BLOBS[@]}"; do
    IFS=: read -r name _ _ sum <<<"$entry"
    [[ "$(blob_state "$name" "$sum")" == ours ]] || run install -m 0644 "$WORK/$name" "$FW_DIR/$name"
  done
  for entry in "${LINKS[@]}"; do
    IFS=: read -r name target <<<"$entry"
    [[ "$(link_state "$name" "$target")" == ours ]] || run ln -s "$target" "$FW_DIR/$name"
  done
  [[ $DRY_RUN -eq 1 ]] && return 0

  # Read back what actually landed on disk instead of trusting the copy.
  log "Reading back ${FW_DIR}/..."
  if ! report_files; then
    err "What's on disk doesn't match what was installed."
    exit 1
  fi
}

# --- step 5: check that the kernel loads it (wakes the card) ----------------

# Mesa's VA-API driver only offers decoding once the kernel has created the
# card's msvld object, which it can't do without loading nve6_fuc084. So the
# decode profiles vainfo lists are the proof. The card goes back to sleep after
# nouveau's autosuspend delay.
probe_firmware() {
  local node t0 out klog fwlog profiles
  log "5. Asking the K2100M's video engine for its decode profiles (wakes the card)..."
  if ! command -v vainfo >/dev/null 2>&1; then
    warn "vainfo is not installed (sudo apt install vainfo), so this check is skipped."
    return 0
  fi
  node="/dev/dri/by-path/pci-${GPU_ADDR}-render"
  if [[ ! -e "$node" ]]; then
    err "$GPU_ADDR has no render node. Is nouveau loaded?"
    return 1
  fi

  t0="$(date +%s)"
  out="$(LIBVA_DRIVER_NAME=nouveau timeout 60 vainfo --display drm --device "$node" 2>&1)"
  sleep 2    # give journald a moment to receive the kernel's messages
  klog="$(journalctl -k --since "@$t0" -o short-monotonic --no-hostname --no-pager 2>&1)"
  fwlog="$(grep -E 'nve6_fuc|msvld|mspdec|msppp' <<<"$klog")"
  profiles="$(awk -F: '/VAEntrypointVLD/ {gsub(/[[:space:]]|VAProfile/, "", $1); print $1}' <<<"$out" | paste -sd' ')"

  if [[ -z "$profiles" ]]; then
    err "VA-API offers no decoding on the K2100M, so the kernel did not load the firmware."
    if [[ -n "$fwlog" ]]; then show <<<"$fwlog"; else show <<<"$out"; fi
    return 1
  fi
  ok "nouveau loaded the firmware: the K2100M decodes $profiles"
  if grep -qiE 'fail|unable' <<<"$fwlog"; then
    warn "but the kernel still logged firmware errors:"
    show <<<"$fwlog"
    return 1
  fi
  return 0
}

# --- --status / --undo ------------------------------------------------------

do_status() {
  local id drv=none power klog fails since newer
  log "GPU"
  if find_gpu; then
    read -r id < "$GPU_DEV/device"
    [[ -L "$GPU_DEV/driver" ]] && drv="$(basename "$(readlink "$GPU_DEV/driver")")"
    power="$(cat "$GPU_DEV/power/runtime_status" 2>/dev/null || echo unknown)"
    echo "    $GPU_ADDR, PCI ID 10de:${id#0x}, driver $drv, power $power"
  else
    warn "no NVIDIA GPU on the PCI bus"
  fi

  log "Firmware in ${FW_DIR}/"
  if [[ -d "$FW_DIR" ]]; then
    report_files
  else
    warn "not installed (the directory doesn't exist)"
  fi

  log "Failed nve6 firmware loads in this boot's kernel log"
  klog="$(journalctl -k -b --no-hostname --no-pager 2>&1)"
  if grep -q 'not seeing messages' <<<"$klog"; then
    warn "can't read the kernel journal - join the adm group, or run: sudo journalctl -k -b | grep nve6_fuc"
    return 0
  fi
  # A failed load logs the requested name, then its ...d fallback: count the former.
  fails="$(grep -E 'Direct firmware load for nouveau/nve6_fuc08[0-9] failed' <<<"$klog")"
  if [[ -z "$fails" ]]; then
    ok "none"
  else
    warn "$(wc -l <<<"$fails") this boot, the last one:"
    tail -n 1 <<<"$fails" | show
    if installed; then
      since="$(stat -c %Y "$FW_DIR/nve0_bsp")"
      newer="$(journalctl -k --since "@$since" --no-pager 2>/dev/null \
               | grep -cE 'Direct firmware load for nouveau/nve6_fuc08[0-9] failed')"
      if (( newer == 0 )); then
        ok "none since the firmware was installed ($(date -d "@$since" '+%F %H:%M'))"
      else
        warn "$newer since the firmware was installed ($(date -d "@$since" '+%F %H:%M'))"
      fi
    fi
  fi
  echo "    To probe the card for real:  ~/scripts/nouveau-video-firmware.sh --test"
}

do_undo() {
  local entry name target sum
  log "Removing what --apply installed from ${FW_DIR}/..."
  if [[ ! -d "$FW_DIR" ]]; then
    ok "Nothing to remove: ${FW_DIR} doesn't exist."
    return 0
  fi
  for entry in "${LINKS[@]}"; do
    IFS=: read -r name target <<<"$entry"
    case "$(link_state "$name" "$target")" in
      ours)
        if run rm -f "$FW_DIR/$name" && [[ $DRY_RUN -eq 0 ]]; then ok "Removed $name"; fi ;;
      missing) ok "$name already gone" ;;
      foreign) warn "$name is not a symlink to $target, leaving it alone" ;;
    esac
  done
  for entry in "${BLOBS[@]}"; do
    IFS=: read -r name _ _ sum <<<"$entry"
    case "$(blob_state "$name" "$sum")" in
      ours)
        if run rm -f "$FW_DIR/$name" && [[ $DRY_RUN -eq 0 ]]; then ok "Removed $name"; fi ;;
      missing) ok "$name already gone" ;;
      foreign) warn "$name is not the file this script installs, leaving it alone" ;;
    esac
  done
  run rmdir --ignore-fail-on-non-empty "$FW_DIR"
  [[ $DRY_RUN -eq 1 ]] && return 0
  [[ -d "$FW_DIR" ]] || ok "Removed ${FW_DIR}/"
  log "The firmware errors return at the next probe of the card; no reboot needed."
}

# --- main -------------------------------------------------------------------

case "$ACTION" in
  status)
    do_status
    exit 0
    ;;
  test)
    check_gpu
    probe_firmware
    exit $?
    ;;
esac

# --apply and --undo change the system: a real run is logged, and it asks for
# sudo before the long download rather than after it.
if [[ $DRY_RUN -eq 1 && "$ACTION" == undo ]]; then
  log "DRY RUN — no changes will be made."
elif [[ $DRY_RUN -eq 1 ]]; then
  log "DRY RUN — steps 1-3 run for real; nothing on the system changes."
else
  c_red=""; c_grn=""; c_ylw=""; c_blu=""; c_rst=""
  LOG_FILE="${SCRIPT_DIR}/nouveau-video-firmware-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee "$LOG_FILE") 2>&1
  LOG_TEE_PID=$!
  log "Logging this run to: ${LOG_FILE}"
  if ! sudo -v; then
    err "This script needs sudo privileges."
    exit 1
  fi
fi

if [[ "$ACTION" == undo ]]; then
  do_undo
  exit 0
fi

check_gpu
if installed; then
  ok "Already installed in ${FW_DIR}/, nothing to download."
else
  check_clashes
  fetch_firmware
  install_firmware
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  log "Dry run complete. Re-run without --dry-run to install."
  exit 0
fi

if ! probe_firmware; then
  err "The files are installed but the check failed. To remove them:"
  err "  ~/scripts/nouveau-video-firmware.sh --undo"
  exit 1
fi
echo
log "Done: nouveau loads its video firmware from now on, no reboot needed."
log "Full log of this run: ${LOG_FILE}"
log "Check anytime:  ~/scripts/nouveau-video-firmware.sh --status"
log "Revert:         ~/scripts/nouveau-video-firmware.sh --undo"
