#!/usr/bin/env bash
#
# fix-nvidia-kepler.sh
#
# Repairs the recurring "NVIDIA-SMI has failed because it couldn't communicate
# with the NVIDIA driver" error on this machine after an NVIDIA package upgrade.
#
# Root cause (Ubuntu 24.04 / noble):
#   * The GPU is a Quadro K2100M (GK106 = Kepler). Kepler is only supported up to
#     the NVIDIA 470 driver branch; the 535 branch dropped Kepler support, so a
#     535 module never binds and nvidia-smi fails ("could not insert 'nvidia':
#     No such device").
#   * WORSE: in noble-updates/restricted the entire 470 branch at version
#     470.256.02-0ubuntu0.24.04.5 was turned into TRANSITIONAL packages that just
#     "Depends: ...-535". So `apt install nvidia-driver-470` silently installs
#     535. That poisoned ...04.5 build is the default candidate, which is why
#     every upgrade re-breaks the machine.
#   * The REAL 470 driver still exists as 470.256.02-0ubuntu0.24.04.1 (from the
#     graphics-drivers PPA and noble-security/restricted).
#
# This script:
#   1. Clears stale nvidia holds.
#   2. Writes an apt pin that blocks the transitional ...04.5 build for good.
#   3. Purges the entire 535 branch (this also drops the transitional 470 meta).
#   4. Installs the REAL nvidia-driver-470 = $REAL_VER metapackage.
#   5. Verifies the 470 DKMS module built for the running kernel.
#   6. Holds the installed 470 packages.
#   7. Loads the module, then asks whether to reboot.
#
# A real run is recorded to a timestamped log next to this script
# (fix-nvidia-kepler-YYYYmmdd-HHMMSS.log) so the result can be reviewed later.
#
# Usage:
#   ./fix-nvidia-kepler.sh            # apply the fix, then ASK before rebooting
#   ./fix-nvidia-kepler.sh --dry-run  # print what would run, change nothing
#   ./fix-nvidia-kepler.sh -n         # same as --dry-run
#   ./fix-nvidia-kepler.sh --reboot   # reboot at the end WITHOUT asking
#
set -uo pipefail

DRY_RUN=0
DO_REBOOT=0
KEEP_BRANCH="470"
DROP_BRANCH="535"
DKMS_OK=0          # set to 1 once the 470 module is confirmed built

# The genuine (non-transitional) 470 driver version on noble.
REAL_VER="470.256.02-0ubuntu0.24.04.1"
# The poisoned transitional version to block forever.
TRANS_VER="470.256.02-0ubuntu0.24.04.5"

PIN_FILE="/etc/apt/preferences.d/nvidia-470-kepler.pref"

# Directory this script lives in (logs land here).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE=""
LOG_TEE_PID=""

for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    --reboot)     DO_REBOOT=1 ;;
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

# --- helpers ----------------------------------------------------------------

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_rst=$'\e[0m'

log()  { echo "${c_blu}==>${c_rst} $*"; }
ok()   { echo "${c_grn}  ok${c_rst} $*"; }
warn() { echo "${c_ylw}  ! ${c_rst} $*"; }
err()  { echo "${c_red}  x ${c_rst} $*" >&2; }

# Run a privileged command, or just print it under --dry-run.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "   ${c_ylw}[dry-run]${c_rst} sudo $*"
  else
    sudo "$@"
  fi
}

# Yes/no prompt that talks straight to the terminal, so it still shows when
# stdout is being piped through tee for logging. Usage: ask "prompt " "y"|"n"
# Returns 0 for yes, 1 for no.
ask() {
  local prompt="$1" default="$2" ans
  if [[ -r /dev/tty ]]; then
    printf '%s' "$prompt" > /dev/tty
    read -r ans < /dev/tty
  else
    read -r -p "$prompt" ans
  fi
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

# For a real run, record everything (stdout+stderr) to a timestamped log and
# drop ANSI colours so the file stays plain-text and easy to read back.
if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY RUN — no changes will be made."
else
  c_red=""; c_grn=""; c_ylw=""; c_blu=""; c_rst=""
  LOG_FILE="${SCRIPT_DIR}/fix-nvidia-kepler-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee "$LOG_FILE") 2>&1
  LOG_TEE_PID=$!
  # bash does not wait for the tee process substitution; flush it on exit so the
  # log is complete (close our fds first so tee sees EOF, then reap it).
  trap 'exec >&- 2>&-; [[ -n "${LOG_TEE_PID:-}" ]] && wait "${LOG_TEE_PID}" 2>/dev/null' EXIT
  log "Logging this run to: ${LOG_FILE}"
fi

# --- 0. sanity checks -------------------------------------------------------

log "Checking this is actually a Kepler / 470-locked machine..."

gpu=$(lspci 2>/dev/null | grep -iE 'nvidia' | grep -iE 'vga|3d' || true)
if [[ -z "$gpu" ]]; then
  err "No NVIDIA GPU found on the PCI bus. Aborting."
  exit 1
fi
echo "    GPU: $gpu"

if grep -qiE 'GK[0-9]|Kepler|Quadro K' <<<"$gpu"; then
  ok "Detected a Kepler-class GPU (needs the ${KEEP_BRANCH} driver)."
else
  warn "Could not positively identify this as Kepler."
  warn "If this card is Maxwell or newer, this script is the WRONG fix — abort."
  if [[ $DRY_RUN -eq 0 ]]; then
    ask "    Continue anyway? [y/N] " "n" || { err "Aborted by user."; exit 1; }
  fi
fi

# The real 470 driver MUST be available before we tear anything down.
log "Verifying the real 470 driver (${REAL_VER}) is installable..."
madison=$(apt-cache madison nvidia-driver-470 2>/dev/null || true)
if grep -qF "$REAL_VER" <<<"$madison"; then
  ok "nvidia-driver-470=${REAL_VER} is available in the repos."
else
  err "nvidia-driver-470=${REAL_VER} not found in any configured repo."
  err "It normally comes from noble-security/restricted or the graphics-drivers PPA."
  err "Refusing to purge the current driver without a working replacement."
  exit 1
fi

# Pre-flight sudo (skip under dry-run).
if [[ $DRY_RUN -eq 0 ]]; then
  if ! sudo -v; then
    err "This script needs sudo privileges."
    exit 1
  fi
fi

# --- 1. clear stale nvidia holds --------------------------------------------

log "Clearing any existing nvidia holds for a clean slate..."
held=$(apt-mark showhold 2>/dev/null | grep -i nvidia || true)
if [[ -n "$held" ]]; then
  echo "$held" | sed 's/^/      unhold /'
  # shellcheck disable=SC2086
  run apt-mark unhold $held
else
  ok "No nvidia holds set."
fi

# --- 2. pin the transitional ...04.5 build out, permanently -----------------

log "Writing apt pin to block the transitional 470->535 build (${TRANS_VER})..."
read -r -d '' PIN_CONTENT <<EOF || true
# Managed by ~/scripts/fix-nvidia-kepler.sh
# This Quadro K2100M is Kepler and cannot use the NVIDIA 535 branch.
# In noble-updates/restricted the 470 packages at ${TRANS_VER} are TRANSITIONAL
# stubs that depend on the 535 branch. Block that exact version so apt always
# selects the real 470 driver (${REAL_VER}) instead.
# NOTE: a 'version' pin must name packages/globs; 'Package: *' is silently
# rejected with "Did not understand pin type version", so list the nvidia globs.
Package: nvidia-* libnvidia-* xserver-xorg-video-nvidia-*
Pin: version ${TRANS_VER}
Pin-Priority: -1
EOF

if [[ $DRY_RUN -eq 1 ]]; then
  echo "   ${c_ylw}[dry-run]${c_rst} write ${PIN_FILE}:"
  echo "$PIN_CONTENT" | sed 's/^/        /'
else
  echo "$PIN_CONTENT" | sudo tee "$PIN_FILE" >/dev/null
  ok "Wrote ${PIN_FILE}"
fi

# --- 3. purge the incompatible 535 branch -----------------------------------

log "Purging the ${DROP_BRANCH} driver branch (incompatible with Kepler)..."
drop_pkgs=$(dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' | grep -E "(^|[-])nvidia.*${DROP_BRANCH}|^libnvidia.*${DROP_BRANCH}" || true)
if [[ -n "$drop_pkgs" ]]; then
  echo "    Will purge:"
  echo "$drop_pkgs" | sed 's/^/      /'
  # shellcheck disable=SC2086
  run apt-get purge -y $drop_pkgs
else
  ok "No ${DROP_BRANCH} packages installed — nothing to purge."
fi

# Also purge any 470 package still sitting at the transitional version.
trans_installed=$(dpkg-query -W -f='${Package}:${Architecture} ${Version}\n' 2>/dev/null \
  | awk -v v="$TRANS_VER" '$2==v {print $1}' || true)
if [[ -n "$trans_installed" ]]; then
  log "Purging leftover transitional 470 packages at ${TRANS_VER}..."
  echo "$trans_installed" | sed 's/^/      /'
  # shellcheck disable=SC2086
  run apt-get purge -y $trans_installed
fi

log "Removing now-orphaned packages..."
run apt-get autoremove -y

# --- 4. install the REAL 470 driver -----------------------------------------

log "Installing the real ${KEEP_BRANCH} driver (nvidia-driver-470=${REAL_VER})..."
run apt-get install -y --allow-downgrades "nvidia-driver-470=${REAL_VER}"

# --- 5. verify the DKMS module built for the running kernel -----------------

kernel=$(uname -r)
log "Checking the ${KEEP_BRANCH} DKMS module built for kernel ${kernel}..."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "   ${c_ylw}[dry-run]${c_rst} dkms status | grep nvidia"
else
  dkms_line=$(dkms status 2>/dev/null | grep -E "nvidia/${KEEP_BRANCH}" | grep "$kernel" || true)
  if grep -qi installed <<<"$dkms_line"; then
    ok "$dkms_line"
    DKMS_OK=1
  else
    warn "Did not see an 'installed' ${KEEP_BRANCH} module for ${kernel}."
    warn "Full dkms status:"
    dkms status 2>/dev/null | sed 's/^/      /'
    warn "Try: sudo dkms autoinstall   (then re-run, or reboot)"
  fi
fi

# --- 6. hold the installed 470 packages -------------------------------------

log "Holding the installed ${KEEP_BRANCH} packages so upgrades can't clobber them..."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "   ${c_ylw}[dry-run]${c_rst} sudo apt-mark hold <all installed *-470 packages>"
else
  # Hold every package now installed at the real 470 version (covers all archs).
  hold_pkgs=$(dpkg-query -W -f='${Package}:${Architecture} ${Version}\n' 2>/dev/null \
    | awk -v v="$REAL_VER" '$2==v {print $1}' || true)
  if [[ -n "$hold_pkgs" ]]; then
    # shellcheck disable=SC2086
    sudo apt-mark hold $hold_pkgs
  else
    warn "No ${KEEP_BRANCH} packages found to hold (install may have failed)."
  fi
fi

# --- 7. load the module, then offer to reboot -------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  log "Dry run complete. Re-run without --dry-run to apply."
  log "A real run logs to ${SCRIPT_DIR}/fix-nvidia-kepler-<timestamp>.log and asks before rebooting."
  exit 0
fi

log "Loading the NVIDIA module..."
sudo modprobe nvidia 2>&1 || warn "modprobe failed now — a reboot will load the fresh module."

log "Verifying with nvidia-smi..."
if nvidia-smi; then
  ok "Driver is responding now."
else
  warn "nvidia-smi not responding yet (normal if old driver state is still resident)."
fi

# --- reboot confirmation ----------------------------------------------------
echo
log "Full log of this run: ${LOG_FILE}"
echo

if [[ "$DKMS_OK" -ne 1 ]]; then
  warn "The 470 DKMS module did NOT report as installed for ${kernel}."
  warn "Rebooting now risks booting WITHOUT a working NVIDIA driver."
  warn "Recommend investigating the DKMS build log before rebooting:"
  warn "    /var/lib/dkms/nvidia/*/build/make.log"
fi

if [[ $DO_REBOOT -eq 1 ]]; then
  log "Auto-reboot requested (--reboot); rebooting now..."
  sudo reboot
  exit 0
fi

# Default to Yes when the module is confirmed, No when it isn't.
if [[ "$DKMS_OK" -eq 1 ]]; then
  prompt="Reboot now to load the 470 driver cleanly? [Y/n] "; default="y"
else
  prompt="Reboot anyway despite the DKMS warning above? [y/N] "; default="n"
fi

if ask "$prompt" "$default"; then
  log "Rebooting..."
  sudo reboot
else
  log "Not rebooting. When ready, run:  sudo reboot"
  log "After reboot, confirm with:  nvidia-smi   (should report driver 470.256.02)"
fi
