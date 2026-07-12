#!/usr/bin/env bash

# ───────────────────────────────────────────────────────────
#   System Update Script
#   - Updates package lists, full-upgrades, cleans up, refreshes snaps
#   - Warns before an available Ubuntu LTS release (Kepler GPU caveat --
#     see fix-nvidia-kepler.sh / switch-to-nouveau.sh)
#   - Prints a formatted recap: timing, package/snap counts, disk
#     usage, reboot status, system info, and local weather
# ───────────────────────────────────────────────────────────

set -euo pipefail   # Exit on errors / undefined variables
IFS=$'\n\t'

#───────────────────────────────────────────────────────────────────────────
# Display: colors, rules, boxed key/value tables
#───────────────────────────────────────────────────────────────────────────
INNER=68                     # box interior width
LABEL_W=22                   # label column width inside a box row
COLS=$(( INNER + 2 ))        # total width of a box / section rule

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'
  RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

log()     { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
success() { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }

# Fill strings for rules/bars. `tr ' ' '─'` mangles multi-byte UTF-8 (it
# cycles raw bytes, not codepoints), so fills are sliced off a pre-built
# string instead.
_RULE="$(printf '─%.0s' $(seq 1 100))"
_HASH="$(printf '#%.0s' $(seq 1 100))"
_DASH="$(printf -- '-%.0s' $(seq 1 100))"

BOX_COLOR="$CYAN"   # border color used by box_top/box_bottom/box_line/box_row

section() {
  local title="$1" rule_len
  rule_len=$(( COLS - ${#title} - 4 ))
  (( rule_len < 1 )) && rule_len=1
  echo
  printf '%s%s── %s %s%s%s\n' \
    "$CYAN" "$BOLD" "$title" "$RESET$CYAN" "${_RULE:0:$rule_len}" "$RESET"
}

box_top() {
  local title="$1" rule_len
  rule_len=$(( INNER - 3 - ${#title} ))
  (( rule_len < 1 )) && rule_len=1
  printf '%s╭─ %s%s%s%s %s╮%s\n' \
    "$BOX_COLOR" "$BOLD" "$title" "$RESET" "$BOX_COLOR" "${_RULE:0:$rule_len}" "$RESET"
}

box_bottom() {
  printf '%s╰%s╯%s\n' "$BOX_COLOR" "${_RULE:0:$INNER}" "$RESET"
}

box_line() {
  local text="$1" pad
  pad=$(( INNER - ${#text} - 2 ))
  (( pad < 0 )) && pad=0
  printf '%s│%s %s%*s %s│%s\n' "$BOX_COLOR" "$RESET" "$text" "$pad" '' "$BOX_COLOR" "$RESET"
}

# box_row <label> <plain-value> [<display-value>]
# `display-value` may carry ANSI color; `plain-value` must have the same
# VISIBLE length (colors excluded) or the right border drifts.
box_row() {
  local label="$1" plain="$2" disp="${3:-$2}" pad
  pad=$(( INNER - LABEL_W - ${#plain} - 3 ))
  (( pad < 0 )) && pad=0
  printf '%s│%s %-*s %s%*s %s│%s\n' \
    "$BOX_COLOR" "$RESET" "$LABEL_W" "$label" "$disp" "$pad" '' "$BOX_COLOR" "$RESET"
}

# make_bar <pct> -> sets BAR_PLAIN / BAR_DISP (colored) usage-bar strings.
# Same 70/90% green/yellow/red thresholds as disk_info.sh, for a consistent
# look across the repo.
make_bar() {
  local pct="${1%\%}" width=20 filled empty color
  case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
  filled=$(( pct * width / 100 )); (( filled > width )) && filled=$width
  empty=$(( width - filled ))
  if   (( pct >= 90 )); then color=$RED
  elif (( pct >= 70 )); then color=$YELLOW
  else                        color=$GREEN
  fi
  BAR_PLAIN="[${_HASH:0:$filled}${_DASH:0:$empty}] ${pct}%"
  BAR_DISP="[${color}${_HASH:0:$filled}${RESET}${_DASH:0:$empty}] ${pct}%"
}

fmt_dur() {
  local s="$1" h m
  h=$(( s / 3600 )); s=$(( s % 3600 ))
  m=$(( s / 60 ));   s=$(( s % 60 ))
  if   (( h > 0 )); then printf '%dh %dm %ds' "$h" "$m" "$s"
  elif (( m > 0 )); then printf '%dm %ds' "$m" "$s"
  else                    printf '%ds' "$s"
  fi
}

trunc() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then printf '%s…' "${s:0:$((max - 1))}"; else printf '%s' "$s"; fi
}

# Parses an apt summary line ("N upgraded, M newly installed, K to remove
# and J not upgraded.") from a log file into n_upg/n_new/n_rm/n_keep. Falls
# back to "?" for all four if the line isn't found (best-effort cosmetics --
# never worth failing the run over).
apt_summary_counts() {
  local log="$1" line nums
  line=$(grep -E '^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove and [0-9]+ not upgraded' "$log" | tail -n1) || line=""
  if [[ -n "$line" ]]; then
    nums=$(sed -E 's/^([0-9]+) upgraded, ([0-9]+) newly installed, ([0-9]+) to remove and ([0-9]+) not upgraded.*/\1 \2 \3 \4/' <<<"$line")
    IFS=' ' read -r n_upg n_new n_rm n_keep <<<"$nums"
  else
    n_upg="?"; n_new="?"; n_rm="?"; n_keep="?"
  fi
}

# ── LTS upgrade check ──────────────────────────────────────────────────────
# On this machine (Quadro K2100M / Kepler), NVIDIA 470 won't build on the
# new LTS kernel. ~/scripts/switch-to-nouveau.sh must run BEFORE upgrading.
_lts_available() {
  command -v do-release-upgrade &>/dev/null || return 1
  local out
  out=$(do-release-upgrade -c 2>&1) || true
  grep -qiE '^New release.*available' <<<"$out"
}

#───────────────────────────────────────────────────────────────────────────
# Pre-flight
#───────────────────────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d -t update-sh.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
UPGRADE_LOG="$TMP_DIR/full-upgrade.log"
AUTOREMOVE_LOG="$TMP_DIR/autoremove.log"
SNAP_LOG="$TMP_DIR/snap-refresh.log"

START_EPOCH=$(date +%s)
START_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
OS_PRETTY="Unknown"
if [ -r /etc/os-release ]; then
  OS_PRETTY="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Unknown}")"
fi
DISK_BEFORE_PCT=$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9') || DISK_BEFORE_PCT=0

box_top "System Update"
box_line "${HOSTNAME}  ·  ${OS_PRETTY}"
box_line "kernel $(uname -r)  ·  started ${START_TIME}"
box_bottom

#───────────────────────────────────────────────────────────────────────────
# Package lists
#───────────────────────────────────────────────────────────────────────────
section "Package lists"
sudo apt update -y

if _lts_available; then
  BOX_COLOR="$YELLOW"
  echo
  box_top "Ubuntu LTS upgrade available"
  box_line "Action required before running do-release-upgrade:"
  box_line ""
  box_line "This machine has a Kepler GPU (Quadro K2100M). The NVIDIA 470"
  box_line "driver is EOL and will NOT build on the new LTS kernel."
  box_line ""
  box_line "  1. Run:     ~/scripts/switch-to-nouveau.sh"
  box_line "  2. Reboot and confirm the desktop still works on nouveau"
  box_line "  3. Then:    sudo do-release-upgrade"
  box_line ""
  box_line "This update (apt full-upgrade) stays on the current release"
  box_line "and is safe to continue. Abort only if you want to deal with"
  box_line "the nouveau switch right now."
  box_bottom
  BOX_COLOR="$CYAN"
  echo
  read -r -p "Continue with this update? [Y/n] " _lts_ans || _lts_ans="n"
  _lts_ans="${_lts_ans:-y}"
  if [[ ! "$_lts_ans" =~ ^[Yy]$ ]]; then
    log "Update aborted. Run ~/scripts/switch-to-nouveau.sh when ready."
    exit 0
  fi
fi

T_UPDATE=$(date +%s)

#───────────────────────────────────────────────────────────────────────────
# Full upgrade
#───────────────────────────────────────────────────────────────────────────
section "Full upgrade"
sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y 2>&1 | tee "$UPGRADE_LOG"
T_UPGRADE=$(date +%s)

apt_summary_counts "$UPGRADE_LOG"
UPG_UPGRADED="$n_upg"; UPG_NEW="$n_new"; UPG_KEEP="$n_keep"

#───────────────────────────────────────────────────────────────────────────
# Cleanup
#───────────────────────────────────────────────────────────────────────────
section "Cleanup"
sudo apt autoremove -y 2>&1 | tee "$AUTOREMOVE_LOG"
apt_summary_counts "$AUTOREMOVE_LOG"
AUTOREMOVED="$n_rm"
sudo apt autoclean -y
T_CLEANUP=$(date +%s)

#───────────────────────────────────────────────────────────────────────────
# Snap refresh
#───────────────────────────────────────────────────────────────────────────
section "Updating Snaps"
sudo snap refresh 2>&1 | tee "$SNAP_LOG"
N_SNAP_REFRESHED=$(grep -cE ' refreshed$' "$SNAP_LOG") || N_SNAP_REFRESHED=0
T_SNAP=$(date +%s)

#───────────────────────────────────────────────────────────────────────────
# Summary
#───────────────────────────────────────────────────────────────────────────
DISK_AFTER_PCT=$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9') || DISK_AFTER_PCT=0
END_EPOCH=$(date +%s)
END_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

REBOOT_REQUIRED=0
[ -f /var/run/reboot-required ] && REBOOT_REQUIRED=1

UPTIME_STR="$(uptime -p 2>/dev/null)" || UPTIME_STR="n/a"
UPTIME_STR="$(trunc "$UPTIME_STR" 40)"
TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null)" || TIMEZONE="n/a"
NTP_SYNCED="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" || NTP_SYNCED="n/a"

section "Summary"

box_top "Update Summary"
box_row "Packages upgraded" "$UPG_UPGRADED"
box_row "Newly installed"   "$UPG_NEW"
box_row "Held back"         "$UPG_KEEP"
box_row "Autoremoved"       "$AUTOREMOVED"
box_row "Snaps refreshed"   "$N_SNAP_REFRESHED"
if [ "$REBOOT_REQUIRED" -eq 1 ]; then
  box_row "Reboot required" "yes" "${YELLOW}${BOLD}yes${RESET}"
else
  box_row "Reboot required" "no"  "${GREEN}no${RESET}"
fi
box_bottom

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
  REBOOT_PKGS=""
  if [ -f /var/run/reboot-required.pkgs ]; then
    REBOOT_PKGS=$(paste -sd, /var/run/reboot-required.pkgs 2>/dev/null) || REBOOT_PKGS=""
  fi
  if [ -n "$REBOOT_PKGS" ]; then
    warn "Reboot required ($(trunc "$REBOOT_PKGS" 50)) -- run: sudo reboot"
  else
    warn "Reboot required -- run: sudo reboot"
  fi
fi
echo

box_top "Timing"
box_row "Package lists" "$(fmt_dur $((T_UPDATE - START_EPOCH)))"
box_row "Full upgrade"  "$(fmt_dur $((T_UPGRADE - T_UPDATE)))"
box_row "Cleanup"       "$(fmt_dur $((T_CLEANUP - T_UPGRADE)))"
box_row "Snap refresh"  "$(fmt_dur $((T_SNAP - T_CLEANUP)))"
box_row "Total"         "$(fmt_dur $((END_EPOCH - START_EPOCH)))"
box_bottom
echo

box_top "Disk (/)"
make_bar "$DISK_BEFORE_PCT"; box_row "Before" "$BAR_PLAIN" "$BAR_DISP"
make_bar "$DISK_AFTER_PCT";  box_row "After"  "$BAR_PLAIN" "$BAR_DISP"
box_bottom
echo

box_top "System"
box_row "Host"       "$HOSTNAME"
box_row "OS release" "$OS_PRETTY"
box_row "Kernel"     "$(uname -r)"
box_row "Uptime"     "$UPTIME_STR"
box_row "Timezone"   "$TIMEZONE"
if [ "$NTP_SYNCED" = "yes" ]; then
  box_row "NTP synced" "yes" "${GREEN}yes${RESET}"
else
  box_row "NTP synced" "$NTP_SYNCED" "${YELLOW}${NTP_SYNCED}${RESET}"
fi
box_bottom

section "Local weather"
weather --latitude 48.215583 --longitude 16.513131 || warn "Could not fetch weather (network down?)"

echo
success "Update completed at $END_TIME (total $(fmt_dur $((END_EPOCH - START_EPOCH))))"
