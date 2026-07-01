#!/usr/bin/env bash

# ───────────────────────────────────────────────────────────
#   System Update Script
#   - Updates package lists
#   - Performs upgrade non-interactively
#   - Shows system info and timing
# ───────────────────────────────────────────────────────────

set -euo pipefail   # Exit on errors / undefined variables
IFS=$'\n\t'

# Colors (optional, for readability)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log()      { echo -e "${BLUE}[INFO]${RESET} $*"; }
success()  { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()     { echo -e "${YELLOW}[WARN]${RESET} $*"; }

START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

log "Update started at $START_TIME"

log "Updating package lists"
sudo apt update -y

# ── LTS upgrade check ──────────────────────────────────────────────────────
# On this machine (Quadro K2100M / Kepler), NVIDIA 470 won't build on the
# new LTS kernel. ~/scripts/switch-to-nouveau.sh must run BEFORE upgrading.
_lts_available() {
  command -v do-release-upgrade &>/dev/null || return 1
  local out
  out=$(do-release-upgrade -c 2>&1) || true
  grep -qiE '^New release.*available' <<<"$out"
}

if _lts_available; then
  echo
  warn "════════════════════════════════════════════════════════════"
  warn "  A new Ubuntu LTS release is available."
  warn ""
  warn "  !! ACTION REQUIRED before running do-release-upgrade !!"
  warn ""
  warn "  This machine has a Kepler GPU (Quadro K2100M). The NVIDIA"
  warn "  470 driver is EOL and will NOT build on the new LTS kernel."
  warn "  Switch to nouveau FIRST:"
  warn ""
  warn "      ~/scripts/switch-to-nouveau.sh"
  warn ""
  warn "  Reboot, confirm the desktop works on nouveau, THEN run:"
  warn "      sudo do-release-upgrade"
  warn ""
  warn "  This update (apt full-upgrade) stays on the current release"
  warn "  and is safe to continue. Abort only if you want to deal"
  warn "  with the nouveau switch right now."
  warn "════════════════════════════════════════════════════════════"
  echo
  read -r -p "Continue with this update? [Y/n] " _lts_ans || _lts_ans="n"
  _lts_ans="${_lts_ans:-y}"
  if [[ ! "$_lts_ans" =~ ^[Yy]$ ]]; then
    log "Update aborted. Run ~/scripts/switch-to-nouveau.sh when ready."
    exit 0
  fi
fi

log "Applying all upgrades (full-upgrade)"
sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y

log "Cleaning up"
sudo apt autoremove -y
sudo apt autoclean -y

log "Updating Snaps"
sudo snap refresh

# 4) Show system info
log "System information:"
uname -a

log "Timezone / clock status:"
timedatectl status

END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
weather --latitude 48.215583 --longitude 16.513131
success "Update completed at $END_TIME"


