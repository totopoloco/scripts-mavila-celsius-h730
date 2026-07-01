#!/usr/bin/env bash
#
# switch-to-nouveau.sh
#
# Companion to fix-nvidia-kepler.sh. Migrates this machine OFF the end-of-life
# proprietary NVIDIA 470 driver and ONTO the open-source nouveau driver.
#
# Why you'd run this:
#   The GPU is a Quadro K2100M (Kepler). NVIDIA 470 is the last proprietary
#   branch that supports Kepler, it is EOL, and it only builds on kernels up to
#   ~6.8. Newer Ubuntu releases (e.g. 26.04 LTS) ship kernels 6.14+ and no real
#   470 package, so the proprietary driver is a dead end there. nouveau is built
#   into the kernel, needs no DKMS, and keeps working on new kernels forever.
#
# What it does:
#   1. Clears the apt holds and removes the apt pin files that fix-nvidia-kepler
#      created (so nothing we added blocks a kernel/release upgrade).
#   2. Purges every proprietary NVIDIA package (470 driver + libs + utils).
#   3. Re-enables nouveau (neutralises any "blacklist nouveau" left behind and
#      backs up stale nvidia modprobe / Xorg configs).
#   4. Installs the nouveau Xorg driver and rebuilds the initramfs.
#   5. Offers to reboot.
#
# RECOMMENDED TIMING: run this while still on your CURRENT, working release
# (e.g. 24.04), reboot, confirm nouveau works, THEN run `do-release-upgrade`.
# Removing the held + PPA-sourced 470 packages first makes the release upgrade
# far less likely to choke. (It is release-agnostic, so running it post-upgrade
# also works — it just won't have helped the upgrade go smoothly.)
#
# A real run is logged to switch-to-nouveau-YYYYmmdd-HHMMSS.log next to this
# script.
#
# Usage:
#   ./switch-to-nouveau.sh            # do the switch, then ASK before rebooting
#   ./switch-to-nouveau.sh --dry-run  # print what would run, change nothing
#   ./switch-to-nouveau.sh -n         # same as --dry-run
#   ./switch-to-nouveau.sh --reboot   # reboot at the end WITHOUT asking
#
set -uo pipefail

DRY_RUN=0
DO_REBOOT=0

# apt preferences files that fix-nvidia-kepler.sh may have created.
PIN_FILES=(
  "/etc/apt/preferences.d/nvidia-470-kepler.pref"
  "/etc/apt/preferences.d/stay-on-ga-kernel.pref"
)

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

# For a real run, record everything to a timestamped log (plain text).
if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY RUN — no changes will be made."
else
  c_red=""; c_grn=""; c_ylw=""; c_blu=""; c_rst=""
  LOG_FILE="${SCRIPT_DIR}/switch-to-nouveau-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee "$LOG_FILE") 2>&1
  LOG_TEE_PID=$!
  trap 'exec >&- 2>&-; [[ -n "${LOG_TEE_PID:-}" ]] && wait "${LOG_TEE_PID}" 2>/dev/null' EXIT
  log "Logging this run to: ${LOG_FILE}"
fi

# --- 0. sanity --------------------------------------------------------------

log "Checking for an NVIDIA GPU on this machine..."
gpu=$(lspci 2>/dev/null | grep -iE 'nvidia' | grep -iE 'vga|3d' || true)
if [[ -z "$gpu" ]]; then
  err "No NVIDIA GPU found on the PCI bus. Nothing for nouveau to take over. Aborting."
  exit 1
fi
echo "    GPU: $gpu"
ok "NVIDIA GPU present — nouveau will drive it after this switch."

if [[ $DRY_RUN -eq 0 ]]; then
  if ! sudo -v; then
    err "This script needs sudo privileges."
    exit 1
  fi
fi

# --- 1. drop holds (nvidia + kernel) so upgrades aren't blocked -------------

log "Clearing apt holds that could block a driver/kernel upgrade..."
held=$(apt-mark showhold 2>/dev/null | grep -iE 'nvidia|^linux-' || true)
if [[ -n "$held" ]]; then
  echo "$held" | sed 's/^/      unhold /'
  # shellcheck disable=SC2086
  run apt-mark unhold $held
else
  ok "No relevant holds set."
fi

# --- 2. remove the apt pin files we created ---------------------------------

log "Removing fix-nvidia-kepler apt pins (re-allows normal kernel/driver resolution)..."
_pin_removed=0
for f in "${PIN_FILES[@]}"; do
  if [[ -e "$f" ]]; then
    _pin_removed=1
    run rm -f "$f"
    [[ $DRY_RUN -eq 0 ]] && ok "Removed $f"
  fi
done
[[ $_pin_removed -eq 0 ]] && ok "No pin files present, nothing to remove."

# --- 3. purge the proprietary NVIDIA stack ----------------------------------

log "Purging proprietary NVIDIA packages..."
# Match both ii (installed) and hi (held-installed); held pkgs show as 'hi'.
nv_pkgs=$(dpkg -l 2>/dev/null | awk '$1 ~ /^[ih]i/ {print $2}' \
  | grep -E '^(nvidia-|libnvidia-|xserver-xorg-video-nvidia)' || true)
if [[ -n "$nv_pkgs" ]]; then
  echo "    Will purge:"
  echo "$nv_pkgs" | sed 's/^/      /'
  # shellcheck disable=SC2086
  run apt-get purge -y $nv_pkgs
else
  ok "No proprietary NVIDIA packages installed."
fi

log "Removing now-orphaned packages..."
run apt-get autoremove -y

# --- 4. re-enable nouveau ---------------------------------------------------

log "Re-enabling nouveau (neutralising any leftover blacklist)..."
# Find modprobe.d files that actively blacklist nouveau or force modeset off.
blk=$(grep -rlE '^[[:space:]]*(blacklist[[:space:]]+nouveau|options[[:space:]]+nouveau([[:space:]].*)?modeset=0)' \
      /etc/modprobe.d /lib/modprobe.d 2>/dev/null || true)
if [[ -n "$blk" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    warn "nouveau is blacklisted in: $f"
    # Comment out the offending lines, keeping a .bak; leaves other content intact.
    run sed -ri.bak \
      's/^[[:space:]]*(blacklist[[:space:]]+nouveau.*|options[[:space:]]+nouveau.*modeset=0.*)$/#&  # disabled by switch-to-nouveau.sh/' \
      "$f"
    [[ $DRY_RUN -eq 0 ]] && ok "Neutralised nouveau blacklist in $f (backup: ${f}.bak)"
  done <<< "$blk"
else
  ok "nouveau is not blacklisted anywhere."
fi

# Back up (don't delete) any stale nvidia-specific modprobe configs left behind.
log "Checking for leftover nvidia modprobe configs..."
nvconf=$(grep -rliE 'nvidia[-_]?drm|nvidia[-_]?modeset|nvidia\.ko' /etc/modprobe.d 2>/dev/null | grep -i nvidia || true)
if [[ -n "$nvconf" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    run mv "$f" "${f}.removed-by-switch-to-nouveau"
    [[ $DRY_RUN -eq 0 ]] && ok "Set aside $f"
  done <<< "$nvconf"
else
  ok "No leftover nvidia modprobe configs."
fi

# Back up any Xorg config that pins the nvidia driver.
log "Checking for nvidia Xorg configs..."
xconf=$(grep -rliE 'Driver[[:space:]]+"nvidia"' /etc/X11/xorg.conf /etc/X11/xorg.conf.d 2>/dev/null || true)
if [[ -n "$xconf" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    run mv "$f" "${f}.removed-by-switch-to-nouveau"
    [[ $DRY_RUN -eq 0 ]] && ok "Set aside nvidia Xorg config $f"
  done <<< "$xconf"
else
  ok "No nvidia Xorg config in the way."
fi

# Warn (don't auto-edit) if the kernel cmdline disables modesetting.
if [[ -f /etc/default/grub ]] && \
   grep -v '^[[:space:]]*#' /etc/default/grub | grep -qE 'nouveau\.modeset=0|(^|[[:space:]])nomodeset'; then
  warn "/etc/default/grub disables kernel modesetting (nomodeset / nouveau.modeset=0)."
  warn "nouveau needs KMS. Edit GRUB_CMDLINE_LINUX* to remove that, then: sudo update-grub"
fi

# --- 5. install the nouveau Xorg driver + rebuild initramfs -----------------

log "Ensuring the nouveau Xorg driver is installed..."
run apt-get install -y xserver-xorg-video-nouveau

log "Rebuilding the initramfs so the changes take effect at boot..."
run update-initramfs -u

# --- 6. enable Wayland in GDM -----------------------------------------------

log "Enabling Wayland in GDM (nouveau supports KMS/Wayland natively)..."
GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "$GDM_CONF" ]]; then
  if grep -qsE '^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*false' "$GDM_CONF"; then
    run sed -i.bak \
      's/^\([[:space:]]*\)WaylandEnable[[:space:]]*=[[:space:]]*false/\1WaylandEnable=true/' \
      "$GDM_CONF"
    [[ $DRY_RUN -eq 0 ]] && ok "Set WaylandEnable=true in $GDM_CONF (backup: ${GDM_CONF}.bak)"
  else
    ok "Wayland already enabled in GDM (no WaylandEnable=false found)."
  fi
else
  ok "$GDM_CONF not present — GDM defaults to Wayland, nothing to do."
fi

# --- 7. wrap up + reboot ----------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  log "Dry run complete. Re-run without --dry-run to apply."
  log "A real run logs to ${SCRIPT_DIR}/switch-to-nouveau-<timestamp>.log and asks before rebooting."
  exit 0
fi

echo
log "Full log of this run: ${LOG_FILE}"
log "After reboot, verify nouveau is driving the GPU with:"
log "    lspci -k | grep -A3 -iE 'vga|3d'      # 'Kernel driver in use: nouveau'"
log "    glxinfo | grep -i renderer            # (from mesa-utils)"
echo
warn "If you are about to upgrade the release, reboot first, confirm the desktop"
warn "comes up on nouveau, THEN run:  sudo do-release-upgrade"
echo

if [[ $DO_REBOOT -eq 1 ]]; then
  log "Auto-reboot requested (--reboot); rebooting now..."
  sudo reboot
  exit 0
fi

if ask "Reboot now to switch over to nouveau? [Y/n] " "y"; then
  log "Rebooting..."
  sudo reboot
else
  log "Not rebooting. When ready, run:  sudo reboot"
fi
