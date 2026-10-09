#!/usr/bin/env bash

# ───────────────────────────────────────────────────────────
#   System Update Script
#   - Updates package lists, full-upgrades, cleans up, refreshes snaps
#   - Warns before an available Ubuntu LTS release: while the NVIDIA card is
#     on the proprietary driver, the Kepler caveat (see fix-nvidia-kepler.sh /
#     switch-to-nouveau.sh); on nouveau, the DKMS modules to check first
#   - Swaps apt's list of upgrades deferred by Ubuntu's phased rollout
#     for a per-update box: rollout %, the % this machine needs, the fix
#   - Prints a formatted recap: timing, package/snap counts, disk
#     usage, reboot status, system info, graphics (GPUs, drivers,
#     GL renderer, session, displays, DKMS), and local weather
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

# Real filesystems only (same list as disk_info.sh) -- skips tmpfs, overlay,
# squashfs (snap loop mounts), proc, and other pseudo mounts.
DISK_FS_TYPES=(ext2 ext3 ext4 xfs btrfs vfat exfat ntfs ntfs3 f2fs zfs)
DISK_TYPE_ARGS=()
for _fs in "${DISK_FS_TYPES[@]}"; do DISK_TYPE_ARGS+=(-t "$_fs"); done

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
# new LTS kernel, so ~/scripts/switch-to-nouveau.sh must run BEFORE upgrading
# -- but only while the card is still on the proprietary driver. On nouveau
# the remaining risk is an out-of-tree DKMS module (evdi) that doesn't build
# on the new kernel: that aborts the kernel's setup before its initramfs.
_lts_available() {
  command -v do-release-upgrade &>/dev/null || return 1
  local out
  out=$(do-release-upgrade -c 2>&1) || true
  grep -qiE '^New release.*available' <<<"$out"
}

# _nvidia_driver_bound: true while a display-class PCI device is bound to the
# proprietary nvidia driver. Reads sysfs like graphics_box, so it can't wake a
# runtime-suspended card.
_nvidia_driver_bound() {
  local dev cls
  for dev in /sys/bus/pci/devices/*; do
    cls="$(cat "$dev/class" 2>/dev/null)" || continue
    [[ "$cls" == 0x03* && -L "$dev/driver" ]] || continue
    if [[ "$(basename "$(readlink "$dev/driver")")" == nvidia ]]; then return 0; fi
  done
  return 1
}

# ── Graphics info ──────────────────────────────────────────────────────────
# Feeds the "Graphics" box in the summary. Best-effort cosmetics: every probe
# may fail and its row is simply left out -- never worth failing an update
# over. Two rules keep the probes from disturbing the hardware they describe:
#   * Names and drivers come from udev/sysfs, never lspci. lspci reads PCI
#     config space, which wakes a runtime-suspended NVIDIA card, and nouveau
#     can power that card off between uses.
#   * The card is only queried (nvidia-smi, hwmon) while it reads "active".

GFX_W=$(( INNER - LABEL_W - 3 ))                  # widest value a box_row fits
GFX_VITALS=""                                     # set by gfx_gpu_vitals
GFX_NVSMI_FAILED=0                                # set by gfx_gpu_vitals
GFX_DKMS=""; GFX_DKMS_KERNEL=""; GFX_DKMS_BAD=0   # set by gfx_dkms_summary

# gfx_row <label> <value> [<color>]: a box_row with label and value clipped to
# their columns; <color> (e.g. "$YELLOW") tints the value.
gfx_row() {
  local label plain
  label="$(trunc "$1" "$LABEL_W")"
  plain="$(trunc "$2" "$GFX_W")"
  if [[ -n "${3:-}" ]]; then
    box_row "$label" "$plain" "${3}${plain}${RESET}"
  else
    box_row "$label" "$plain"
  fi
}

# gfx_gpu_name <pci-sysfs-dir>: short "Vendor Model" from the udev hwdb, e.g.
# "NVIDIA Quadro K2100M"; falls back to the raw PCI id.
gfx_gpu_name() {
  local dev="$1" props vendor model
  props="$(udevadm info -q property -p "$dev" 2>/dev/null)" || props=""
  vendor="$(sed -n 's/^ID_VENDOR_FROM_DATABASE=//p' <<<"$props")"
  model="$(sed -n 's/^ID_MODEL_FROM_DATABASE=//p' <<<"$props")"
  vendor="${vendor% Corporation}"
  if [[ "$model" =~ \[(.+)\] ]]; then model="${BASH_REMATCH[1]}"; fi
  model="${model/ Integrated Graphics Controller/ iGPU}"
  if [[ -n "$model" ]]; then
    printf '%s' "${vendor:+$vendor }$model"
  else
    printf 'PCI %s:%s' "$(cat "$dev/vendor" 2>/dev/null)" "$(cat "$dev/device" 2>/dev/null)"
  fi
  return 0
}

# gfx_driver_desc <driver>: "nvidia 470.256.02 (proprietary)", "i915 (in-kernel)".
gfx_driver_desc() {
  local drv="$1" ver=""
  if [[ -z "$drv" ]]; then printf 'no driver bound'; return 0; fi
  ver="$(cat "/sys/module/$drv/version" 2>/dev/null)" || ver=""
  case "$drv" in
    nvidia) printf 'nvidia %s (proprietary)' "${ver:-?}" ;;
    *)      printf '%s%s (in-kernel)' "$drv" "${ver:+ $ver}" ;;
  esac
  return 0
}

# gfx_gpu_vitals <pci-sysfs-dir> <driver>: sets GFX_VITALS to e.g.
# "P8 · 52°C · 4/2002 MiB" (nvidia-smi) or "47°C" (nouveau's hwmon), and
# GFX_NVSMI_FAILED=1 if nvidia-smi can't reach its driver. Call it only for a
# card that reads "active": either probe would wake a suspended one.
gfx_gpu_vitals() {
  local dev="$1" drv="$2" out ps temp mem_used mem_total t
  GFX_VITALS=""
  if [[ "$drv" == nvidia ]]; then
    if out="$(timeout 10 nvidia-smi -i "${dev##*/}" \
        --query-gpu=pstate,temperature.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits 2>&1)"; then
      IFS=', ' read -r ps temp mem_used mem_total <<<"$out"
      GFX_VITALS="${ps} · ${temp}°C · ${mem_used}/${mem_total} MiB"
    else
      GFX_NVSMI_FAILED=1
      GFX_VITALS="nvidia-smi: $(head -n1 <<<"$out")"
    fi
  else
    for t in "$dev"/hwmon/hwmon*/temp1_input; do
      temp="$(cat "$t" 2>/dev/null)" || continue
      GFX_VITALS="$(( temp / 1000 ))°C"
      break
    done
  fi
  return 0
}

# gfx_dkms_summary: for the graphics DKMS modules (nvidia, evdi) sets GFX_DKMS
# ("evdi 1.14.7, nvidia 470.256.02"), GFX_DKMS_KERNEL (newest installed kernel)
# and GFX_DKMS_BAD=1 if any module is not installed for that kernel. That is
# the failure that leaves a GPU without its driver after the next reboot.
gfx_dkms_summary() {
  local kern_new lines
  GFX_DKMS=""; GFX_DKMS_KERNEL=""; GFX_DKMS_BAD=0
  command -v dkms >/dev/null 2>&1 || return 0
  kern_new="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
    | awk '$1 == "ii" { sub(/^linux-image-/, "", $2); print $2 }' | sort -V | tail -n1)" || kern_new=""
  GFX_DKMS_KERNEL="${kern_new:-$(uname -r)}"
  # "nvidia/470.256.02, 6.8.0-142-generic, x86_64: installed": fields split on / , :
  lines="$(dkms status 2>/dev/null | awk -F'[/,:] *' -v k="$GFX_DKMS_KERNEL" '
    $1 ~ /^(nvidia|evdi)/ && NF >= 5 {
      seen[$1] = 1
      if ($3 == k && $5 ~ /^installed/) have[$1] = $2
    }
    END { for (m in seen) print m, ((m in have) ? have[m] : "MISSING") }' | sort)" || lines=""
  if [[ -n "$lines" ]]; then
    GFX_DKMS="$(paste -sd, <<<"$lines" | sed 's/,/, /g')"
    if [[ "$lines" == *MISSING* ]]; then GFX_DKMS_BAD=1; fi
  fi
  return 0
}

# graphics_box: the "Graphics" summary box (plus any warnings under it).
graphics_box() {
  local dev cls addr drv bv state val sess glx renderer glver
  local c st name card conn ddrv
  local -A conns=()
  GFX_NVSMI_FAILED=0

  box_top "Graphics"

  # Every display-class PCI device: card, driver and -- for one that isn't the
  # boot GPU (the NVIDIA offload card here) -- its runtime power state.
  for dev in /sys/bus/pci/devices/*; do
    cls="$(cat "$dev/class" 2>/dev/null)" || continue
    [[ "$cls" == 0x03* ]] || continue
    addr="${dev##*/}"
    drv=""
    if [[ -L "$dev/driver" ]]; then drv="$(basename "$(readlink "$dev/driver")")"; fi
    gfx_row "GPU ${addr#0000:}" "$(gfx_gpu_name "$dev")"
    gfx_row "  driver" "$(gfx_driver_desc "$drv")"
    bv="$(cat "$dev/boot_vga" 2>/dev/null)" || bv=""
    if [[ "$bv" != 1 ]]; then
      state="$(cat "$dev/power/runtime_status" 2>/dev/null)" || state="unknown"
      val="$state"
      GFX_VITALS=""
      if [[ "$state" == active ]]; then
        gfx_gpu_vitals "$dev" "$drv"
        if [[ -n "$GFX_VITALS" ]]; then val="$state · $GFX_VITALS"; fi
      elif [[ "$state" == suspended ]]; then
        val="suspended (idle)"
      fi
      if (( GFX_NVSMI_FAILED )); then gfx_row "  power" "$val" "$YELLOW"; else gfx_row "  power" "$val"; fi
    fi
  done

  # Default OpenGL renderer (deliberately not DRI_PRIME=1: that would wake the
  # offload card; ~/scripts/verify-nouveau.sh does the offload test).
  glx="$(timeout 10 glxinfo -B 2>/dev/null)" || glx=""
  renderer="$(sed -n 's/^OpenGL renderer string: //p' <<<"$glx")"
  glver="$(sed -n 's/^OpenGL version string: //p' <<<"$glx")"
  if [[ -n "$renderer" ]]; then
    gfx_row "GL renderer" "$renderer"
    if [[ "$glver" =~ ^([0-9.]+).*Mesa\ ([0-9.]+) ]]; then
      gfx_row "OpenGL" "${BASH_REMATCH[1]} · Mesa ${BASH_REMATCH[2]}"
    else
      gfx_row "OpenGL" "$glver"
    fi
  else
    gfx_row "GL renderer" "unavailable (needs glxinfo + DISPLAY)"
  fi

  sess="${XDG_SESSION_TYPE:-unknown}"
  if [[ "$sess" == x11 ]] \
     && grep -Eqs '^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*false' /etc/gdm3/custom.conf; then
    sess="x11 (Wayland disabled in GDM)"
  fi
  gfx_row "Session" "$sess"

  # Connected displays, grouped by the driver of the card that drives them.
  # A connector has no "device" link of its own, so go through its card node.
  for c in /sys/class/drm/card*-*; do
    st="$(cat "$c/status" 2>/dev/null)" || continue
    [[ "$st" == connected ]] || continue
    name="${c##*/}"          # card5-eDP-1
    card="${name%%-*}"       # card5
    conn="${name#*-}"        # eDP-1
    ddrv="?"
    if [[ -L "/sys/class/drm/$card/device/driver" ]]; then
      ddrv="$(basename "$(readlink "/sys/class/drm/$card/device/driver")")"
    fi
    conns[$ddrv]+="${conns[$ddrv]:+, }$conn"
  done
  if (( ${#conns[@]} )); then
    for ddrv in $(printf '%s\n' "${!conns[@]}" | sort); do
      gfx_row "Displays on $ddrv" "${conns[$ddrv]}"
    done
  fi

  gfx_dkms_summary
  if [[ -n "$GFX_DKMS" ]]; then
    val="$GFX_DKMS"
    if [[ "$GFX_DKMS_KERNEL" != "$(uname -r)" ]]; then val="${GFX_DKMS_KERNEL%-generic}: $val"; fi
    if (( GFX_DKMS_BAD )); then gfx_row "Graphics DKMS" "$val" "$RED"; else gfx_row "Graphics DKMS" "$val"; fi
  fi

  box_bottom

  if (( GFX_DKMS_BAD )); then
    warn "DKMS has no built graphics module for kernel ${GFX_DKMS_KERNEL}: booting it would leave that GPU without its driver (check: dkms status)"
  fi
  if (( GFX_NVSMI_FAILED )); then
    warn "nvidia-smi can't reach the NVIDIA driver -- if a reboot doesn't cure it, run ~/scripts/fix-nvidia-kepler.sh"
  fi
  return 0
}

# ── Phased updates ─────────────────────────────────────────────────────────
# Ubuntu rolls bug-fix updates out in phases: each one starts at 10% of
# machines and is raised while errors.ubuntu.com shows no new crashes (0%
# means the rollout was stopped; security updates never phase). apt decides
# once per source package, so one update can defer a dozen binaries. The full
# upgrade's output therefore swaps apt's package list for a one-line pointer,
# and the summary's "Phased updates" box lists the updates instead. Best-effort
# cosmetics, like the Graphics box.

# phase_draw <source>-<source version>-<machine id>: this machine's draw
# (0-100) for that update; apt defers the update while the draw is above its
# rollout percentage. A bash port of the std::seed_seq -> std::minstd_rand ->
# std::uniform_int_distribution(0, 100) chain in apt 3.2's
# IsIgnoredPhasedUpdate (apt-pkg/depcache.cc), following libstdc++. Words are
# kept mod 2^32, like the uint32 arithmetic they mirror.
phase_draw() {
  local str="$1" s=${#1} n=4 p=1 q=2 m i k x r1 r2 c
  local -a b=(0x8b8b8b8b 0x8b8b8b8b 0x8b8b8b8b 0x8b8b8b8b) v=()
  for (( i = 0; i < s; i++ )); do printf -v c '%d' "'${str:i:1}"; v+=("$c"); done
  # seed_seq::generate into the 4 words minstd_rand asks for (n = 4: t = 1, p = 1, q = 2)
  m=$(( s + 1 > n ? s + 1 : n ))
  for (( k = 0; k < m; k++ )); do
    x=$(( b[k % n] ^ b[(k + p) % n] ^ b[(k + n - 1) % n] ))
    r1=$(( 1664525 * (x ^ (x >> 27)) & 0xFFFFFFFF ))
    if   (( k == 0 )); then r2=$(( (r1 + s) & 0xFFFFFFFF ))
    elif (( k <= s )); then r2=$(( (r1 + k % n + v[k - 1]) & 0xFFFFFFFF ))
    else                    r2=$(( (r1 + k % n) & 0xFFFFFFFF ))
    fi
    b[(k + p) % n]=$(( (b[(k + p) % n] + r1) & 0xFFFFFFFF ))
    b[(k + q) % n]=$(( (b[(k + q) % n] + r2) & 0xFFFFFFFF ))
    b[k % n]=$r2
  done
  for (( k = m; k < m + n; k++ )); do
    x=$(( (b[k % n] + b[(k + p) % n] + b[(k + n - 1) % n]) & 0xFFFFFFFF ))
    r1=$(( 1566083941 * (x ^ (x >> 27)) & 0xFFFFFFFF ))
    r2=$(( (r1 - k % n) & 0xFFFFFFFF ))
    b[(k + p) % n]=$(( b[(k + p) % n] ^ r1 ))
    b[(k + q) % n]=$(( b[(k + q) % n] ^ r2 ))
    b[k % n]=$r2
  done
  # minstd_rand starts at word 3 mod (2^31 - 1), never 0; uniform_int_distribution
  # then takes libstdc++'s reject-and-divide path: 101 buckets of 21262214.
  x=$(( b[3] % 2147483647 )); (( x != 0 )) || x=1
  while :; do
    x=$(( 48271 * x % 2147483647 ))
    (( x - 1 >= 2147483614 )) || break
  done
  echo $(( (x - 1) / 21262214 ))
}

# phase_step <source>: points one run of Ubuntu's phased-updater adds to a
# rollout (PUP_INCREMENT, with its MEDIUM_PACKAGES and SLOW_PACKAGES, in
# ubuntu-archive-tools' phased-updater). It only feeds the "~N steps" estimate.
phase_step() {
  case "$1" in
    openssh|openssl|rust-coreutils)                                    echo 5 ;;
    grub2|grub2-signed|grub2-unsigned|shim|shim-signed|secureboot-db) echo 1 ;;
    *)                                                                 echo 10 ;;
  esac
}

# phase_fix <binary>=<version>: "<LP refs>\x1f<first bullet>\x1f<other bullets>"
# from the top entry of that version's changelog, which apt fetches from
# changelogs.ubuntu.com (prints nothing when it can't). A leading
# "d/p/<patch>: " is dropped and the "(LP: #n)" split off, so the fix itself
# gets the room.
phase_fix() {
  timeout 10 apt-get changelog "$1" 2>/dev/null | awk '
    / urgency=/ { if (seen++) exit; next }
    !seen       { next }
    /^ -- /     { exit }
    /^  \* /    { if (++n == 1) { t = $0; sub(/^  \* /, "", t); inb = 1 } else inb = 0; next }
    inb && /^    [^ *+-]/ { s = $0; sub(/^ +/, "", s); t = t " " s; next }
                { inb = 0 }
    END {
      if (t == "") exit
      lp = ""
      if (match(t, /\(?LP: *#[0-9]+(, *#[0-9]+)*\)?/)) {
        lp = substr(t, RSTART, RLENGTH)
        t = substr(t, 1, RSTART - 1) substr(t, RSTART + RLENGTH)
        gsub(/[^0-9#,]/, "", lp); gsub(/,/, ", ", lp); lp = "LP " lp
      }
      sub(/^(d|debian)\/[^ ]+: */, "", t)
      gsub(/  +/, " ", t); sub(/ +$/, "", t)
      printf "%s\037%s\037%d\n", lp, t, n - 1
    }' || true
}

# hide_phasing_list: copies apt-get's output through, but swaps its "deferred
# due to phasing" package list for a pointer to the Phased updates box. Only
# apt's plan is read line by line: from its "N upgraded, ..." line on, cat
# passes the rest straight through, so a dpkg prompt that doesn't end in a
# newline (a changed conffile) still shows the moment dpkg asks.
hide_phasing_list() {
  local line in_list=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( in_list )) && [[ "$line" == ' '* ]]; then continue; fi
    in_list=0
    if [[ "$line" == 'The following upgrades have been deferred due to phasing:' ]]; then
      log "Phasing deferred some upgrades: see \"Phased updates\" in the summary"
      in_list=1
      continue
    fi
    printf '%s\n' "$line"
    if [[ "$line" =~ ^[0-9]+\ upgraded, ]]; then exec cat; fi
  done
  return 0
}

# phasing_box: the "Phased updates" box for what this run's full upgrade
# deferred -- one entry per update, soonest first, with the first fix from its
# changelog -- and a blank line after it. Prints nothing if apt deferred nothing.
phasing_box() {
  local -a bins=()
  local -A first=() bver=() sver=() pct=() nbin=() rank=() val=()
  local mid="" never="" never_um="" b src sv v pu draw step steps w order lp fix more n_upd n_pkgs
  mapfile -t bins < <(awk '
    /^The following upgrades have been deferred due to phasing:$/ { f = 1; next }
    f && /^ / { for (i = 1; i <= NF; i++) print $i; next }
    f         { exit }' "$UPGRADE_LOG")
  (( ${#bins[@]} )) || return 0

  # Each binary's candidate -> source, source version, rollout percentage. No
  # percentage means 100%: the rollout finished after apt made its plan.
  while IFS=$'\x1f' read -r b src sv v pu; do
    nbin[$src]=$(( ${nbin[$src]:-0} + 1 ))
    if [[ -z "${first[$src]:-}" ]]; then
      [[ "$pu" =~ ^[0-9]+$ ]] || pu=100
      first[$src]="$b"; bver[$src]="$v"; sver[$src]="$sv"; pct[$src]="$pu"
    fi
  done < <(apt-cache show --no-all-versions "${bins[@]}" 2>/dev/null | awk '
    function out() {
      if (p != "") printf "%s\037%s\037%s\037%s\037%s\n", p, (s == "" ? p : s), (sv == "" ? v : sv), v, pu
      p = ""
    }
    /^Package: / { out(); p = $2; s = sv = v = pu = "" }
    /^Source: /  { s = $2; if (match($0, /\(.*\)/)) sv = substr($0, RSTART + 1, RLENGTH - 2) }
    /^Version: / { v = $2 }
    /^Phased-Update-Percentage: / { pu = $2 }
    END { out() }')

  box_top "Phased updates"
  if (( ${#first[@]} == 0 )); then
    box_line "apt-cache has no details on the ${#bins[@]} deferred packages"
    box_bottom
    echo
    return 0
  fi

  # Same machine ID and opt-outs apt reads.
  eval "$(apt-config shell mid APT::Machine-ID never APT::Get::Never-Include-Phased-Updates/b \
    never_um Update-Manager::Never-Include-Phased-Updates/b 2>/dev/null)"
  [[ -n "$mid" ]] || mid="$(head -n1 /etc/machine-id 2>/dev/null)" || mid=""
  never="${never:-${never_um:-false}}"

  for src in "${!first[@]}"; do   # changelogs download in parallel
    phase_fix "${first[$src]}=${bver[$src]}" >"$TMP_DIR/phase-fix.$src" &
  done
  wait

  for src in "${!first[@]}"; do
    pu="${pct[$src]}"
    w="${nbin[$src]} pkgs"; (( nbin[$src] != 1 )) || w="1 pkg"
    if (( pu == 0 )); then
      val[$src]="$w · rollout stopped at 0%"; rank[$src]=999
    elif [[ "$never" == true ]]; then
      val[$src]="$w · $pu% now · waits for 100%"; rank[$src]=998
    else
      draw="$(phase_draw "$src-${sver[$src]}-$mid")"
      if (( draw <= pu )); then
        val[$src]="$w · $pu% now · due next run"; rank[$src]=0
      else
        step="$(phase_step "$src")"
        rank[$src]=$(( (draw - pu + step - 1) / step ))
        steps="~${rank[$src]} steps"; (( rank[$src] != 1 )) || steps="~1 step"
        val[$src]="$w · $pu% now · needs $draw% · $steps"
      fi
    fi
  done

  n_upd="${#first[@]} updates"; (( ${#first[@]} != 1 )) || n_upd="1 update"
  n_pkgs="${#bins[@]} packages"; (( ${#bins[@]} != 1 )) || n_pkgs="1 package"
  box_line "Not rolled out to this machine yet: $n_upd ($n_pkgs)"
  order="$(for src in "${!first[@]}"; do printf '%s %s\n' "${rank[$src]}" "$src"; done \
    | sort -k1,1n -k2,2 | cut -d' ' -f2)"
  for src in $order; do
    if (( rank[$src] == 999 )); then gfx_row "$src" "${val[$src]}" "$YELLOW"; else gfx_row "$src" "${val[$src]}"; fi
    lp=""; fix=""; more=0
    if [[ -s "$TMP_DIR/phase-fix.$src" ]]; then IFS=$'\x1f' read -r lp fix more <"$TMP_DIR/phase-fix.$src"; fi
    [[ -n "$fix" ]] || continue
    if (( more > 0 )); then fix="$(trunc "$fix" $(( GFX_W - 9 - ${#more} ))) (+$more more)"; fi
    gfx_row "  $lp" "$fix"
  done
  box_bottom
  echo
  return 0
}

#───────────────────────────────────────────────────────────────────────────
# Pre-flight
#───────────────────────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d -t update-sh.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
PREFLIGHT_LOG="$TMP_DIR/preflight-upgrade.log"
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

sudo apt-get dist-upgrade -s 2>&1 | tee "$PREFLIGHT_LOG" >/dev/null || true
apt_summary_counts "$PREFLIGHT_LOG"
PRE_UPGRADED="$n_upg"; PRE_NEW="$n_new"; PRE_REMOVE="$n_rm"; PRE_KEEP="$n_keep"

DL_SIZE=$(sed -nE 's/^Need to get (.*) of archives\.?$/\1/p' "$PREFLIGHT_LOG") || DL_SIZE=""
[ -z "$DL_SIZE" ] && DL_SIZE="0 B"

DISK_RAW=$(sed -nE 's/^After this operation, (.*)\.$/\1/p' "$PREFLIGHT_LOG") || DISK_RAW=""
if [ -n "$DISK_RAW" ]; then
  IFS=' ' read -r _dsz _dunit _ <<<"$DISK_RAW"
  if [[ "$DISK_RAW" == *freed ]]; then DISK_DELTA="${_dsz} ${_dunit} freed"
  else                                  DISK_DELTA="${_dsz} ${_dunit} used"
  fi
else
  DISK_DELTA="no change"
fi

echo
box_top "Available Updates"
box_row "To upgrade"      "$PRE_UPGRADED"
box_row "Newly installed" "$PRE_NEW"
box_row "To remove"       "$PRE_REMOVE"
box_row "Held back"       "$PRE_KEEP"
box_row "Download size"   "$DL_SIZE"
box_row "Disk space"      "$DISK_DELTA"
box_bottom

if _lts_available; then
  BOX_COLOR="$YELLOW"
  echo
  box_top "Ubuntu LTS upgrade available"
  if _nvidia_driver_bound; then
    box_line "Action required before running do-release-upgrade:"
    box_line ""
    box_line "This machine has a Kepler GPU (Quadro K2100M). The NVIDIA 470"
    box_line "driver is EOL and will NOT build on the new LTS kernel."
    box_line ""
    box_line "  1. Run:     ~/scripts/switch-to-nouveau.sh"
    box_line "  2. Reboot and confirm the desktop still works on nouveau"
    box_line "  3. Then:    sudo do-release-upgrade"
    box_line ""
    box_line "This update (apt-get dist-upgrade) stays on the current release"
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
  else
    gfx_dkms_summary
    box_line "The NVIDIA card is not on the proprietary driver, so no nouveau"
    box_line "switch is needed before running do-release-upgrade."
    if [[ -n "$GFX_DKMS" ]]; then
      box_line ""
      box_line "First confirm these DKMS modules support the new LTS kernel:"
      box_line "  $GFX_DKMS"
      box_line "One that fails to build leaves that kernel without an initramfs."
    fi
    box_bottom
    BOX_COLOR="$CYAN"
  fi
fi

T_UPDATE=$(date +%s)

#───────────────────────────────────────────────────────────────────────────
# Full upgrade
#───────────────────────────────────────────────────────────────────────────
section "Full upgrade"
sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1 | tee "$UPGRADE_LOG" | hide_phasing_list
T_UPGRADE=$(date +%s)

apt_summary_counts "$UPGRADE_LOG"
UPG_UPGRADED="$n_upg"; UPG_NEW="$n_new"; UPG_KEEP="$n_keep"

#───────────────────────────────────────────────────────────────────────────
# Cleanup
#───────────────────────────────────────────────────────────────────────────
section "Cleanup"
sudo apt-get autoremove -y 2>&1 | tee "$AUTOREMOVE_LOG"
apt_summary_counts "$AUTOREMOVE_LOG"
AUTOREMOVED="$n_rm"
sudo apt autoclean -y
T_CLEANUP=$(date +%s)

#───────────────────────────────────────────────────────────────────────────
# Snap refresh
#───────────────────────────────────────────────────────────────────────────
section "Updating Snaps"
# SNAP_REEXEC=0: skip snapd's re-exec into the bundled snapd-snap copy of
# itself. On this machine that copy can't resolve libX11 (pulled in by
# Citrix App Protection's global /etc/ld.so.preload) because its private
# ld.so.cache doesn't know about Ubuntu's multiarch lib paths. The daemon
# gets this same setting from /var/lib/snapd/environment/snapd.conf, but
# that file only applies to snapd.service, not this ad-hoc client call.
if sudo SNAP_REEXEC=0 snap refresh 2>&1 | tee "$SNAP_LOG"; then
  N_SNAP_REFRESHED=$(grep -cE ' refreshed$' "$SNAP_LOG") || N_SNAP_REFRESHED=0
else
  if grep -q 'libX11.so.6: cannot open shared object file' "$SNAP_LOG"; then
    warn "snap/snapd can't load libX11 -- Citrix App Protection's /etc/ld.so.preload"
    warn "breaks snapd's re-exec into its bundled (snapd-snap) copy of itself."
    warn "fix (one-time, needs sudo):"
    warn "  echo 'SNAP_REEXEC=0' | sudo tee /var/lib/snapd/environment/snapd.conf"
    warn "  sudo systemctl daemon-reload && sudo systemctl reset-failed snapd.service"
    warn "  sudo systemctl restart snapd.service"
  else
    warn "snap refresh failed -- continuing without it (see output above)"
  fi
  N_SNAP_REFRESHED=0
fi
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

INTERNAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.*src ([0-9.]+).*/\1/p') || INTERNAL_IP=""
[ -z "$INTERNAL_IP" ] && INTERNAL_IP="n/a"

# OpenDNS resolver first (fast, no HTTP dependency); ifconfig.me as fallback.
EXTERNAL_IP=$(dig +short +time=3 +tries=1 myip.opendns.com @resolver1.opendns.com 2>/dev/null) || EXTERNAL_IP=""
[[ "$EXTERNAL_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || EXTERNAL_IP=$(curl -fs4 --max-time 3 https://ifconfig.me 2>/dev/null) || EXTERNAL_IP=""
if [ -z "$EXTERNAL_IP" ]; then
  EXTERNAL_IP="unavailable"
  warn "Could not determine external IP (network down?)"
fi

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

phasing_box || true

box_top "Timing"
box_row "Package lists" "$(fmt_dur $((T_UPDATE - START_EPOCH)))"
box_row "Full upgrade"  "$(fmt_dur $((T_UPGRADE - T_UPDATE)))"
box_row "Cleanup"       "$(fmt_dur $((T_CLEANUP - T_UPGRADE)))"
box_row "Snap refresh"  "$(fmt_dur $((T_SNAP - T_CLEANUP)))"
box_row "Total"         "$(fmt_dur $((END_EPOCH - START_EPOCH)))"
box_bottom
echo

box_top "Disks"
make_bar "$DISK_BEFORE_PCT"; box_row "/ (before)" "$BAR_PLAIN" "$BAR_DISP"
make_bar "$DISK_AFTER_PCT";  box_row "/ (after)"  "$BAR_PLAIN" "$BAR_DISP"
while IFS=' ' read -r d_target d_fstype d_size d_used d_avail d_pcent; do
  [ "$d_target" = "/" ] && continue
  make_bar "$d_pcent"
  box_row "$(trunc "${d_target} (${d_fstype})" "$LABEL_W")" \
    "${d_used}/${d_size}  ${BAR_PLAIN}" "${d_used}/${d_size}  ${BAR_DISP}"
done < <(df -h "${DISK_TYPE_ARGS[@]}" --output=target,fstype,size,used,avail,pcent 2>/dev/null | tail -n +2 | tr -s ' ' | sed -E 's/^ //')
box_bottom
echo

box_top "System"
box_row "Host"       "$HOSTNAME"
box_row "OS release" "$OS_PRETTY"
box_row "Kernel"     "$(uname -r)"
box_row "Uptime"     "$UPTIME_STR"
box_row "Internal IP" "$INTERNAL_IP"
box_row "External IP" "$EXTERNAL_IP"
box_row "Timezone"   "$TIMEZONE"
if [ "$NTP_SYNCED" = "yes" ]; then
  box_row "NTP synced" "yes" "${GREEN}yes${RESET}"
else
  box_row "NTP synced" "$NTP_SYNCED" "${YELLOW}${NTP_SYNCED}${RESET}"
fi
box_bottom

echo
graphics_box || true

section "Local weather"
weather --latitude 48.215583 --longitude 16.513131 || warn "Could not fetch weather (network down?)"

echo
success "Update completed at $END_TIME (total $(fmt_dur $((END_EPOCH - START_EPOCH))))"
