#!/usr/bin/env bash
#===============================================================================
# performance-tuning.sh
#
# Maximum-performance / no-power-saving tuning for this specific machine:
#   Host    : Fujitsu CELSIUS H730  (BIOS 1.21, 2019)
#   CPU     : Intel Core i7-4910MQ (Haswell, 4C/8T, 0.8-3.9 GHz, intel_pstate passive)
#   RAM     : 32 GiB  (+ zram swap)
#   OS      : Ubuntu 24.04 LTS (Noble), kernel 6.8, systemd
#
# WHAT THIS DOES
#   Applies the OS-level tuning described in the Oracle Database 19c pre-install
#   guide (https://oracle-base.com/articles/19c/oracle-db-19c-installation-on-oracle-linux-9)
#   that is relevant to raw performance, AND disables every laptop power-saving
#   feature so the machine always runs flat-out. It does NOT install Oracle.
#
#   The Oracle "Manual Setup" steps are adapted for Ubuntu, and a few items from
#   the Oracle doc are deliberately changed or skipped (see NOTES below) because
#   they would either reduce performance on THIS host or only matter to a running
#   Oracle instance. Every such decision is commented inline.
#
# PERSISTENCE
#   * Kernel params -> /etc/sysctl.d/99-performance.conf
#   * Resource limits -> /etc/security/limits.d/99-performance.conf
#   * Wi-Fi powersave -> /etc/NetworkManager/conf.d/99-performance-wifi-powersave-off.conf
#   * Runtime knobs (CPU governor, turbo, PCIe ASPM, SATA ALPM, USB autosuspend,
#     HDD spindown, Wi-Fi, power-profiles-daemon) are re-applied on every boot by
#     a tiny systemd unit (performance-tuning.service) that runs the installed
#     copy of this script with --boot-apply.
#
# REVERSIBILITY
#   Before changing anything, the CURRENT state of every runtime knob is captured
#   into /var/backups/performance-tuning/. `--undo` restores those captured values,
#   removes all the drop-in files and the systemd unit, and reloads the relevant
#   services. No reboot is needed for either apply or undo.
#
# USAGE
#   ./performance-tuning.sh --dry-run        # show what apply would do (no root needed)
#   ./performance-tuning.sh --apply          # apply everything (default; needs root)
#   ./performance-tuning.sh --undo           # restore original state (needs root)
#   ./performance-tuning.sh --undo --dry-run # show what undo would do
#   ./performance-tuning.sh --status         # show current vs desired for key knobs
#   ./performance-tuning.sh --iobench        # read-only disk throughput probe (needs root)
#   ./performance-tuning.sh --help
#
#   apply/undo escalate with sudo automatically if not run as root.
#
# NOTES on deviations from the Oracle 19c doc (intentional, for THIS host):
#   * fs.file-max         : OMITTED. The doc sets 6815744; this kernel already
#                           defaults to ~9.2e18 (effectively unlimited). Setting
#                           the doc value would LOWER it -> skipped.
#   * kernel.panic_on_oops: OMITTED. Auto-panic on oops is undesirable on a
#                           general-purpose workstation.
#   * Transparent HugePages: LEFT AT DEFAULT (madvise). The doc disables THP for
#                           Oracle's latency profile; for general desktop/dev work
#                           THP=madvise performs better, so it is not changed.
#   * HugePages (vm.nr_hugepages): SKIPPED. Only useful for an Oracle SGA; would
#                           waste RAM here.
#   * SysV IPC limits (sem/shm*): kept for fidelity to the doc; inert without Oracle.
#   * thermald            : intentionally NOT disabled. On a 12-year-old laptop it
#                           is the safety net that prevents thermal damage while
#                           the CPU runs at full performance.
#===============================================================================

set -uo pipefail

#------------------------------------------------------------------------------
# Constants
#------------------------------------------------------------------------------
VERSION="1.0.0"
SELF_REALPATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

STATE_DIR="/var/backups/performance-tuning"
MANIFEST="$STATE_DIR/manifest"
SNAP_SCALARS="$STATE_DIR/scalars.env"
SNAP_GOV="$STATE_DIR/cpu_governor.snap"
SNAP_USB="$STATE_DIR/usb_control.snap"
SNAP_ALPM="$STATE_DIR/sata_alpm.snap"
SNAP_HDD="$STATE_DIR/hdd_apm.snap"
SNAP_WIFI="$STATE_DIR/wifi_powersave.snap"
SNAP_GSET="$STATE_DIR/gsettings.snap"
SNAP_SYSCTL="$STATE_DIR/sysctl.snap"

# Every sysctl key this script writes via $SYSCTL_FILE. Captured pre-apply so
# --undo can put the live kernel values back (removing the drop-in + reloading
# does NOT reset a key to its compiled-in default).
SYSCTL_KEYS=(
  vm.swappiness
  net.core.rmem_default net.core.rmem_max
  net.core.wmem_default net.core.wmem_max
  net.core.somaxconn net.core.netdev_max_backlog
  net.ipv4.ip_local_port_range
  net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
  fs.aio-max-nr
  kernel.sem kernel.shmmni kernel.shmall kernel.shmmax
)

SYSCTL_FILE="/etc/sysctl.d/99-performance.conf"
LIMITS_FILE="/etc/security/limits.d/99-performance.conf"
NM_FILE="/etc/NetworkManager/conf.d/99-performance-wifi-powersave-off.conf"
SERVICE_NAME="performance-tuning.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
INSTALLED_COPY="/usr/local/sbin/performance-tuning.sh"

DRYRUN=0
ACTION="apply"     # apply | undo | status | boot-apply
ORIG_ARGS=("$@")
DESK_USER=""

# gsettings keys we manage (schema|key|desired-value)
GSETTINGS_KEYS=(
  "org.gnome.settings-daemon.plugins.power|sleep-inactive-ac-type|'nothing'"
  "org.gnome.settings-daemon.plugins.power|sleep-inactive-battery-type|'nothing'"
  "org.gnome.settings-daemon.plugins.power|idle-dim|false"
  "org.gnome.settings-daemon.plugins.power|power-saver-profile-on-low-battery|false"
  "org.gnome.desktop.session|idle-delay|uint32 0"
)

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DRY=$'\033[35m'; C_HDR=$'\033[1m'
else
  C_RST=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_DRY=""; C_HDR=""
fi
info() { printf '%s[*]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { [ "${DRYRUN:-0}" = 1 ] && return 0; printf '%s[+]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }
dry()  { printf '%s[dry-run]%s would %s\n' "$C_DRY" "$C_RST" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_HDR" "$*" "$C_RST"; }

#------------------------------------------------------------------------------
# Generic helpers
#------------------------------------------------------------------------------

# Run a command, or just describe it in dry-run mode.
run() {
  if [ "$DRYRUN" = 1 ]; then dry "run: $*"; return 0; fi
  "$@"
}

# Write a single value to a sysfs/procfs node (idempotent, dry-run aware).
#   set_node <path> <value> [label]
set_node() {
  local path="$1" val="$2" label="${3:-$1}" cur
  if [ ! -e "$path" ]; then warn "skip (not present): $label"; return 0; fi
  if [ ! -w "$path" ] && [ "$DRYRUN" != 1 ]; then warn "skip (not writable): $label"; return 0; fi
  cur="$(cat "$path" 2>/dev/null)"
  if [ "$DRYRUN" = 1 ]; then dry "set $label : '$cur' -> '$val'"; return 0; fi
  if printf '%s' "$val" > "$path" 2>/dev/null; then
    ok "$label = $val ${cur:+(was: $cur)}"
  else
    warn "failed to set $label"
  fi
}

# Write a managed config file (dry-run aware). Content via stdin.
write_managed_file() {
  local path="$1" content; content="$(cat)"
  if [ "$DRYRUN" = 1 ]; then
    dry "write $path:"
    printf '%s\n' "$content" | sed 's/^/        | /'
    return 0
  fi
  install -d -m 0755 "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod 0644 "$path"
  ok "wrote $path"
}

remove_file() {
  local path="$1"
  if [ ! -e "$path" ]; then return 0; fi
  if [ "$DRYRUN" = 1 ]; then dry "remove $path"; return 0; fi
  rm -f "$path" && ok "removed $path"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    info "Root privileges required for --$ACTION; re-running with sudo..."
    exec sudo -- "$SELF_REALPATH" "${ORIG_ARGS[@]}"
  fi
}

# Figure out the desktop user (for gsettings). Prefer the sudo caller.
detect_desktop_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    echo "$SUDO_USER"; return 0
  fi
  # Fall back to the active graphical (seat) session.
  loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$0 ~ /seat/ {print $3; exit}'
}

# Run gsettings as the desktop user against their session bus. Echoes nothing
# on failure. Usage: gsettings_user get|set <schema> <key> [value...]
gsettings_user() {
  local op="$1" schema="$2" key="$3"; shift 3
  [ -n "$DESK_USER" ] || return 1
  local uid bus
  uid="$(id -u "$DESK_USER" 2>/dev/null)" || return 1
  bus="/run/user/$uid/bus"
  [ -S "$bus" ] || return 1
  sudo -u "$DESK_USER" \
       DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
       gsettings "$op" "$schema" "$key" "$@" 2>/dev/null
}

# Enumerate rotational (spinning) disks as /dev/<name>.
rotational_disks() {
  local d
  for d in /sys/block/sd* /sys/block/nvme* /sys/block/hd*; do
    [ -e "$d" ] || continue
    [ "$(cat "$d/queue/rotational" 2>/dev/null)" = "1" ] || continue
    echo "/dev/$(basename "$d")"
  done
}

# Enumerate whole-disk block devices as /dev/<name> (physical disks only --
# skips loopback, zram, device-mapper, and md/RAID devices).
physical_disks() {
  local d name
  for d in /sys/block/*; do
    [ -e "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      loop*|zram*|dm-*|md*) continue ;;
    esac
    echo "/dev/$name"
  done
}

#==============================================================================
# RUNTIME KNOBS  (used by both --apply and the boot service via --boot-apply)
#==============================================================================
apply_runtime() {
  hdr "CPU: performance governor + turbo"
  local g
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$g" ] || continue
    set_node "$g" "performance" "governor ${g#/sys/devices/system/cpu/}"
  done
  # intel_pstate: make sure turbo is ON and the ceiling is 100%.
  set_node /sys/devices/system/cpu/intel_pstate/no_turbo     "0"   "intel_pstate.no_turbo (0=turbo on)"
  set_node /sys/devices/system/cpu/intel_pstate/max_perf_pct "100" "intel_pstate.max_perf_pct"
  # (min_perf_pct is intentionally left alone: pinning it to 100 only bakes in
  #  extra heat at idle with no throughput gain - the performance governor already
  #  jumps to max frequency under load.)

  hdr "power-profiles-daemon: performance profile"
  if command -v powerprofilesctl >/dev/null 2>&1; then
    if powerprofilesctl list 2>/dev/null | grep -q 'performance'; then
      run powerprofilesctl set performance && ok "power profile = performance"
    else
      warn "power-profiles-daemon has no 'performance' profile; skipping"
    fi
  else
    info "powerprofilesctl not present; skipping power profile"
  fi

  hdr "PCIe ASPM: disable link power saving"
  set_node /sys/module/pcie_aspm/parameters/policy "performance" "pcie_aspm.policy"

  hdr "SATA: disable link power management (ALPM)"
  local h
  for h in /sys/class/scsi_host/host*/link_power_management_policy; do
    [ -e "$h" ] || continue
    set_node "$h" "max_performance" "ALPM ${h#/sys/class/scsi_host/}"
  done

  hdr "USB: disable autosuspend on all devices"
  local u
  for u in /sys/bus/usb/devices/*/power/control; do
    [ -e "$u" ] || continue
    set_node "$u" "on" "usb ${u#/sys/bus/usb/devices/}"
  done

  hdr "Disks: keep spinning disks from sleeping"
  if command -v hdparm >/dev/null 2>&1; then
    local dev
    while read -r dev; do
      [ -n "$dev" ] || continue
      # -S 0  : disable standby (spindown) timer
      # -B 254: maximum performance APM level (no aggressive head-parking/spindown)
      if [ "$DRYRUN" = 1 ]; then
        dry "run: hdparm -S 0 -B 254 $dev"
      else
        if hdparm -S 0 -B 254 "$dev" >/dev/null 2>&1; then
          ok "disabled spindown/APM on $dev"
        else
          warn "could not set APM on $dev (drive may not support it)"
        fi
      fi
    done < <(rotational_disks)
  else
    info "hdparm not installed; skipping HDD spindown (install with: apt install hdparm)"
  fi

  hdr "Wi-Fi: disable power saving (runtime)"
  if command -v iw >/dev/null 2>&1; then
    local i
    for i in /sys/class/net/wl*; do
      [ -e "$i" ] || continue
      i="$(basename "$i")"
      if [ "$DRYRUN" = 1 ]; then
        dry "run: iw dev $i set power_save off"
      else
        iw dev "$i" set power_save off >/dev/null 2>&1 \
          && ok "wifi power_save off on $i" \
          || info "wifi power_save not set on $i (interface may be down; NM config covers it)"
      fi
    done
  else
    info "iw not installed; relying on NetworkManager config for Wi-Fi powersave"
  fi
}

#==============================================================================
# SNAPSHOT  (capture current state before first apply)
#==============================================================================
take_snapshot() {
  if [ -f "$MANIFEST" ]; then
    info "Snapshot already exists at $STATE_DIR — preserving the original baseline."
    return 0
  fi
  if [ "$DRYRUN" = 1 ]; then dry "snapshot current runtime state into $STATE_DIR"; return 0; fi

  install -d -m 0700 "$STATE_DIR"

  # Per-CPU governor
  : > "$SNAP_GOV"
  local g
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$g" ] && printf '%s %s\n' "$g" "$(cat "$g" 2>/dev/null)" >> "$SNAP_GOV"
  done

  # USB autosuspend
  : > "$SNAP_USB"
  local u
  for u in /sys/bus/usb/devices/*/power/control; do
    [ -e "$u" ] && printf '%s %s\n' "$u" "$(cat "$u" 2>/dev/null)" >> "$SNAP_USB"
  done

  # SATA ALPM
  : > "$SNAP_ALPM"
  local h
  for h in /sys/class/scsi_host/host*/link_power_management_policy; do
    [ -e "$h" ] && printf '%s %s\n' "$h" "$(cat "$h" 2>/dev/null)" >> "$SNAP_ALPM"
  done

  # HDD APM (numeric level if hdparm can read it)
  : > "$SNAP_HDD"
  if command -v hdparm >/dev/null 2>&1; then
    local dev lvl
    while read -r dev; do
      [ -n "$dev" ] || continue
      lvl="$(hdparm -B "$dev" 2>/dev/null | sed -n 's/.*APM_level[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p')"
      printf '%s %s\n' "$dev" "${lvl:-unknown}" >> "$SNAP_HDD"
    done < <(rotational_disks)
  fi

  # Wi-Fi powersave per interface
  : > "$SNAP_WIFI"
  if command -v iw >/dev/null 2>&1; then
    local i st
    for i in /sys/class/net/wl*; do
      [ -e "$i" ] || continue
      i="$(basename "$i")"
      st="$(iw dev "$i" get power_save 2>/dev/null | sed -n 's/.*Power save:[[:space:]]*\([a-z]*\).*/\1/p')"
      printf '%s %s\n' "$i" "${st:-unknown}" >> "$SNAP_WIFI"
    done
  fi

  # gsettings (desktop power) per managed key
  : > "$SNAP_GSET"
  if [ -n "$DESK_USER" ]; then
    local entry schema key val
    for entry in "${GSETTINGS_KEYS[@]}"; do
      IFS='|' read -r schema key _ <<< "$entry"
      val="$(gsettings_user get "$schema" "$key")" || val=""
      [ -n "$val" ] && printf '%s|%s|%s\n' "$schema" "$key" "$val" >> "$SNAP_GSET"
    done
  fi

  # Scalars
  local aspm_active
  aspm_active="$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p' /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
  {
    echo "VERSION=$VERSION"
    echo "DATE=$(date -Is 2>/dev/null)"
    echo "no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
    echo "max_perf_pct=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null)"
    echo "min_perf_pct=$(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null)"
    echo "pcie_aspm=${aspm_active:-default}"
    echo "ppd_profile=$(command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl get 2>/dev/null)"
    echo "swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)"
    echo "desk_user=$DESK_USER"
  } > "$SNAP_SCALARS"

  # Original runtime sysctl values (tab-delimited; tab preserves multi-field
  # values like "32768<tab>60999" and "250 32000 100 128").
  : > "$SNAP_SYSCTL"
  local k v
  for k in "${SYSCTL_KEYS[@]}"; do
    v="$(sysctl -n "$k" 2>/dev/null)" || continue
    printf '%s\t%s\n' "$k" "$v" >> "$SNAP_SYSCTL"
  done

  printf 'performance-tuning.sh v%s\napplied: %s\nhost: %s\n' \
    "$VERSION" "$(date 2>/dev/null)" "$(hostname 2>/dev/null)" > "$MANIFEST"
  ok "captured original state into $STATE_DIR"
}

#==============================================================================
# CONFIG FILE CONTENTS
#==============================================================================
sysctl_content() {
cat <<'EOF'
# Managed by performance-tuning.sh -- remove via: performance-tuning.sh --undo
#
# Kernel parameters from the Oracle Database 19c pre-install guide
# (oracle-base.com) that aid performance, plus a few general tuneables.
# See script header for parameters from the Oracle doc that are intentionally
# omitted on this host (fs.file-max, kernel.panic_on_oops).

# --- Asynchronous I/O & networking throughput (Oracle pre-install set) ---
fs.aio-max-nr = 1048576
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
# Reverse-path filter in "loose" mode (2): correct for multi-homed / VPN / docker hosts.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# Wider ephemeral port range. The Oracle doc specifies "9000 65500"; that lower
# bound is DELIBERATELY RAISED to 16384 on this host. Fixed-port services here
# listen in the 9000-16383 band (e.g. Ollama on 11434), and an ephemeral source
# port colliding with them causes intermittent EADDRINUSE bind failures on
# restart. Starting at 16384 still enlarges the pool well beyond the kernel
# default (32768 60999) while staying clear of those service ports.
net.ipv4.ip_local_port_range = 16384 65500

# --- System V IPC limits (from the Oracle doc; inert without an Oracle DB) ---
kernel.sem = 250 32000 100 128
kernel.shmmni = 4096
kernel.shmall = 1073741824
kernel.shmmax = 4398046511104

# --- General performance extras (not from the Oracle doc) ---
# Prefer RAM/page-cache over swapping (zram swap is configured on this host).
vm.swappiness = 10
# Larger listen/backlog queues help busy servers & docker workloads.
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
EOF
}

limits_content() {
cat <<'EOF'
# Managed by performance-tuning.sh -- remove via: performance-tuning.sh --undo
#
# Generous resource limits for a high-performance workstation, generalized from
# the Oracle 19c pre-install limits (which targeted the dedicated 'oracle' user).
# Group-specific limits from other drop-ins (e.g. @pipewire, @gamemode) still win
# for their members, since username/group domains outrank the '*' wildcard.

# Max open file descriptors
*       soft    nofile      65535
*       hard    nofile      1048576
root    soft    nofile      65535
root    hard    nofile      1048576

# Max user processes
*       soft    nproc       65535
*       hard    nproc       131072
root    soft    nproc       65535
root    hard    nproc       131072

# Max stack size (KB). Raise the soft limit (default 8192) but keep the hard
# limit unlimited -- this host's default hard stack is "unlimited", and capping
# it would silently break deep-recursion / `ulimit -s unlimited` workloads.
*       soft    stack       32768
*       hard    stack       unlimited

# Max locked-in-memory address space (KB)
*       soft    memlock     134217728
*       hard    memlock     134217728
EOF
}

nm_content() {
cat <<'EOF'
# Managed by performance-tuning.sh -- remove via: performance-tuning.sh --undo
# wifi.powersave = 2  -> disable Wi-Fi power saving
[connection]
wifi.powersave = 2
EOF
}

service_content() {
cat <<EOF
[Unit]
Description=Maximum performance tuning (governor, turbo, ASPM/ALPM/USB/Wi-Fi power saving off)
Documentation=file://$INSTALLED_COPY
After=sysinit.target power-profiles-daemon.service NetworkManager.service
Wants=power-profiles-daemon.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALLED_COPY --boot-apply

[Install]
WantedBy=multi-user.target
EOF
}

#==============================================================================
# APPLY
#==============================================================================
do_apply() {
  hdr "Capturing current state (for --undo)"
  take_snapshot

  hdr "Kernel parameters -> $SYSCTL_FILE"
  sysctl_content | write_managed_file "$SYSCTL_FILE"
  if [ "$DRYRUN" = 1 ]; then dry "run: sysctl -p $SYSCTL_FILE"; else
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 && ok "kernel parameters applied" \
      || warn "sysctl -p reported errors (some keys may not exist on this kernel)"
  fi

  hdr "Resource limits -> $LIMITS_FILE"
  limits_content | write_managed_file "$LIMITS_FILE"
  info "limits.conf changes take effect on next login/session."

  hdr "Wi-Fi powersave config -> $NM_FILE"
  nm_content | write_managed_file "$NM_FILE"
  if command -v nmcli >/dev/null 2>&1; then
    run nmcli general reload >/dev/null 2>&1 && ok "NetworkManager reloaded" || true
  fi

  # Runtime knobs (immediate effect)
  apply_runtime

  hdr "Desktop session: disable screen dim / idle power saving"
  if [ -n "$DESK_USER" ]; then
    local entry schema key val cur
    for entry in "${GSETTINGS_KEYS[@]}"; do
      IFS='|' read -r schema key val <<< "$entry"
      cur="$(gsettings_user get "$schema" "$key")" || cur="?"
      if [ "$DRYRUN" = 1 ]; then
        dry "gsettings($DESK_USER) $key : $cur -> $val"
      else
        # shellcheck disable=SC2086
        if gsettings_user set "$schema" "$key" $val; then
          ok "gsettings $key = $val (was $cur)"
        else
          warn "could not set gsettings $key (no active session?)"
        fi
      fi
    done
  else
    info "No desktop user/session detected; skipping GNOME power settings."
  fi

  hdr "Persistence: install boot-time service"
  if [ "$DRYRUN" = 1 ]; then
    dry "install $SELF_REALPATH -> $INSTALLED_COPY (0755, root)"
    dry "write $SERVICE_FILE"
    dry "run: systemctl daemon-reload"
    dry "run: systemctl enable $SERVICE_NAME"
  else
    install -m 0755 -o root -g root "$SELF_REALPATH" "$INSTALLED_COPY" \
      && ok "installed $INSTALLED_COPY"
    service_content > "$SERVICE_FILE" && chmod 0644 "$SERVICE_FILE" && ok "wrote $SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 \
      && ok "enabled $SERVICE_NAME (re-applies runtime knobs every boot)" \
      || warn "could not enable $SERVICE_NAME"
  fi

  hdr "Done"
  if [ "$DRYRUN" = 1 ]; then
    info "Dry run only — nothing was changed."
  else
    ok "Performance tuning applied. No reboot required."
    info "Verify with:  $0 --status"
    info "Revert with:  sudo $0 --undo"
  fi
}

#==============================================================================
# UNDO
#==============================================================================
restore_runtime() {
  hdr "Restoring runtime knobs from snapshot"

  # Governors
  if [ -f "$SNAP_GOV" ]; then
    local path val
    while read -r path val; do
      [ -n "$path" ] && set_node "$path" "$val" "governor ${path#/sys/devices/system/cpu/}"
    done < "$SNAP_GOV"
  fi

  # USB
  if [ -f "$SNAP_USB" ]; then
    local path val
    while read -r path val; do
      [ -n "$path" ] && set_node "$path" "$val" "usb ${path#/sys/bus/usb/devices/}"
    done < "$SNAP_USB"
  fi

  # SATA ALPM
  if [ -f "$SNAP_ALPM" ]; then
    local path val
    while read -r path val; do
      [ -n "$path" ] && set_node "$path" "$val" "ALPM ${path#/sys/class/scsi_host/}"
    done < "$SNAP_ALPM"
  fi

  # Scalars
  if [ -f "$SNAP_SCALARS" ]; then
    # shellcheck disable=SC1090
    . "$SNAP_SCALARS"
    [ -n "${no_turbo:-}" ]     && set_node /sys/devices/system/cpu/intel_pstate/no_turbo     "$no_turbo"     "intel_pstate.no_turbo"
    [ -n "${max_perf_pct:-}" ] && set_node /sys/devices/system/cpu/intel_pstate/max_perf_pct "$max_perf_pct" "intel_pstate.max_perf_pct"
    [ -n "${min_perf_pct:-}" ] && set_node /sys/devices/system/cpu/intel_pstate/min_perf_pct "$min_perf_pct" "intel_pstate.min_perf_pct"
    [ -n "${pcie_aspm:-}" ]    && set_node /sys/module/pcie_aspm/parameters/policy           "$pcie_aspm"    "pcie_aspm.policy"
    if [ -n "${ppd_profile:-}" ] && command -v powerprofilesctl >/dev/null 2>&1; then
      run powerprofilesctl set "$ppd_profile" && ok "power profile -> $ppd_profile" || true
    fi
  fi

  # HDD APM
  if [ -f "$SNAP_HDD" ] && command -v hdparm >/dev/null 2>&1; then
    local dev lvl
    while read -r dev lvl; do
      [ -n "$dev" ] || continue
      case "$lvl" in
        ''|unknown) info "HDD $dev: original APM unknown; leaving at current value" ;;
        *) if [ "$DRYRUN" = 1 ]; then dry "run: hdparm -B $lvl $dev";
           else hdparm -B "$lvl" "$dev" >/dev/null 2>&1 && ok "restored APM=$lvl on $dev" || warn "could not restore APM on $dev"; fi ;;
      esac
      # Note: apply also set the standby/spindown timer (hdparm -S 0). That timer
      # is write-only (not queryable) so it cannot be snapshotted; it is volatile
      # and returns to the drive's firmware default automatically on next reboot.
      info "HDD $dev: spindown timer (-S) is volatile; it reverts to firmware default on reboot."
    done < "$SNAP_HDD"
  fi

  # Wi-Fi
  if [ -f "$SNAP_WIFI" ] && command -v iw >/dev/null 2>&1; then
    local iface st
    while read -r iface st; do
      [ -n "$iface" ] || continue
      case "$st" in
        on|off)
          if [ "$DRYRUN" = 1 ]; then dry "run: iw dev $iface set power_save $st";
          else iw dev "$iface" set power_save "$st" >/dev/null 2>&1 && ok "wifi power_save $st on $iface" || true; fi ;;
        *) : ;;
      esac
    done < "$SNAP_WIFI"
  fi
}

restore_gsettings() {
  [ -f "$SNAP_GSET" ] || return 0
  hdr "Restoring GNOME power settings"
  # desk_user may come from snapshot scalars; DESK_USER already set in main.
  local schema key val
  while IFS='|' read -r schema key val; do
    [ -n "$schema" ] || continue
    if [ "$DRYRUN" = 1 ]; then
      dry "gsettings($DESK_USER) restore $key -> $val"
    else
      # shellcheck disable=SC2086
      gsettings_user set "$schema" "$key" $val \
        && ok "gsettings $key restored to $val" \
        || warn "could not restore gsettings $key"
    fi
  done < "$SNAP_GSET"
}

do_undo() {
  if [ ! -f "$MANIFEST" ] && [ "$DRYRUN" != 1 ]; then
    warn "No snapshot found at $STATE_DIR — this host may not have been tuned by this script."
    info "Will still remove any managed drop-in files / service if present."
  fi

  hdr "Removing boot-time service"
  if [ "$DRYRUN" = 1 ]; then
    dry "run: systemctl disable --now $SERVICE_NAME"
    dry "remove $SERVICE_FILE"
    dry "remove $INSTALLED_COPY"
    dry "run: systemctl daemon-reload"
  else
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    remove_file "$SERVICE_FILE"
    remove_file "$INSTALLED_COPY"
    systemctl daemon-reload
  fi

  hdr "Removing kernel-parameter drop-in"
  remove_file "$SYSCTL_FILE"
  # Re-apply whatever the surviving config files specify...
  if [ "$DRYRUN" = 1 ]; then dry "run: sysctl --system (re-apply remaining configs)"; else
    sysctl --system >/dev/null 2>&1 && ok "reloaded sysctl from remaining config" || true
  fi
  # ...then authoritatively restore the original RUNTIME values we captured.
  # (Removing the drop-in + `sysctl --system` does NOT reset a key whose value
  #  lives in no remaining config file back to its kernel default.)
  if [ -f "$SNAP_SYSCTL" ]; then
    local k v
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] || continue
      if [ "$DRYRUN" = 1 ]; then
        dry "run: sysctl -w \"$k=$v\""
      else
        sysctl -w "$k=$v" >/dev/null 2>&1 && ok "restored $k = $v" || warn "could not restore $k"
      fi
    done < "$SNAP_SYSCTL"
  elif [ "$DRYRUN" = 1 ]; then
    dry "restore original sysctl runtime values from $SNAP_SYSCTL"
  fi

  hdr "Removing resource-limits drop-in"
  remove_file "$LIMITS_FILE"
  info "limits revert on next login/session."

  hdr "Removing Wi-Fi powersave drop-in"
  remove_file "$NM_FILE"
  if command -v nmcli >/dev/null 2>&1; then
    run nmcli general reload >/dev/null 2>&1 && ok "NetworkManager reloaded" || true
  fi

  # Restore captured runtime values + gsettings
  restore_runtime
  restore_gsettings

  hdr "Cleanup"
  if [ "$DRYRUN" = 1 ]; then
    dry "remove state dir $STATE_DIR"
    info "Dry run only — nothing was changed."
  else
    rm -rf "$STATE_DIR" && ok "removed $STATE_DIR"
    ok "System restored to its captured original state. No reboot required."
  fi
}

#==============================================================================
# STATUS
#==============================================================================
show_one() { printf '  %-34s : %s\n' "$1" "$2"; }
do_status() {
  hdr "performance-tuning.sh status (v$VERSION)"
  show_one "tuning applied" "$( [ -f "$MANIFEST" ] && echo yes || echo no )"
  local _en; _en="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)"
  show_one "boot service enabled" "${_en:-absent}"
  echo
  show_one "CPU governor (cpu0)" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  show_one "intel_pstate no_turbo" "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null) (0=turbo on)"
  show_one "intel_pstate max_perf_pct" "$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null)"
  show_one "power profile" "$(command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl get 2>/dev/null || echo n/a)"
  show_one "PCIe ASPM policy" "$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
  show_one "SATA ALPM (host0)" "$(cat /sys/class/scsi_host/host0/link_power_management_policy 2>/dev/null)"
  show_one "USB autosuspend (sample)" "$(cat /sys/bus/usb/devices/*/power/control 2>/dev/null | sort | uniq -c | tr '\n' ' ')"
  show_one "vm.swappiness" "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
  show_one "net.core.rmem_max" "$(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
  show_one "ip_local_port_range" "$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)"
  local i
  for i in /sys/class/net/wl*; do
    [ -e "$i" ] || continue; i="$(basename "$i")"
    show_one "wifi power_save ($i)" "$(command -v iw >/dev/null 2>&1 && iw dev "$i" get power_save 2>/dev/null | sed -n 's/.*Power save:[[:space:]]*//p' || echo n/a)"
  done
  show_one "CPU package temp" "$(awk 'BEGIN{t=0} {t=$1} END{printf "%.0f C", t/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
  echo
}

#==============================================================================
# IOBENCH  (read-only disk throughput probe; needs root to open the raw devices)
#==============================================================================

# Friendly names for the disks on THIS machine (checked against `lsblk -dn -o
# NAME,VENDOR,MODEL,SIZE,ROTA,TRAN` -- raw VENDOR/MODEL strings are too messy
# to show as-is: e.g. sda's VENDOR is just "ATA", sdc's is a truncated model
# number). Anything not listed falls back to disk_generic_label().
disk_label() {
  case "$(basename "$1")" in
    sda) echo "Internal SSD -- Samsung 512GB (SATA)" ;;
    sdb) echo "External SSD -- Samsung T7 (USB)" ;;
    sdc) echo "External HDD -- Seagate 3TB (USB)" ;;
    *)   disk_generic_label "$1" ;;
  esac
}

disk_generic_label() {
  local dev="$1" name kind bus model size
  name="$(basename "$dev")"
  [ "$(cat "/sys/block/$name/queue/rotational" 2>/dev/null)" = "1" ] && kind="HDD" || kind="SSD"
  case "$(lsblk -dn -o TRAN "$dev" 2>/dev/null)" in
    usb) bus="External" ;;
    *)   bus="Internal" ;;
  esac
  model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  size="$(lsblk -dn -o SIZE "$dev" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  printf '%s %s -- %s (%s)' "$bus" "$kind" "${model:-unknown model}" "${size:-unknown size}"
}

# Plain-English verdict for a buffered-disk-read MB/sec figure. hdparm times a
# single-queue-depth sequential read (no NCQ/parallel I/O), which is realistic
# for a spinning disk but systematically under-reports SSDs -- so SSD and HDD
# get different bands. Returns "n/a" if $1 isn't a plain number.
rate_buffered() {
  awk -v v="$1" -v rot="$2" 'BEGIN {
    if (v !~ /^[0-9]+(\.[0-9]+)?$/) { print "n/a"; exit }
    if (rot == "1") {
      if      (v < 80)  print "slow for a spinning disk"
      else if (v < 180) print "typical spinning-disk speed"
      else              print "fast for a spinning disk"
    } else {
      if      (v < 200) print "slow for an SSD"
      else if (v < 350) print "OK for an SSD"
      else              print "fast SSD"
    }
  }'
}

do_iobench() {
  hdr "Disk I/O throughput (read-only benchmark)"

  if ! command -v hdparm >/dev/null 2>&1; then
    err "hdparm not installed; install with: apt install hdparm"
    return 1
  fi

  local dev name line cached buffered rotational found=0
  while read -r dev; do
    [ -n "$dev" ] || continue
    found=1
    name="$(basename "$dev")"
    echo
    echo "$name -- $(disk_label "$dev")"
    if [ "$DRYRUN" = 1 ]; then
      dry "run: hdparm -Tt $dev"
      continue
    fi
    if ! line="$(hdparm -Tt "$dev" 2>&1)"; then
      warn "could not benchmark $name (permission denied, or unsupported over this bus)"
      continue
    fi
    cached="$(sed -n 's/^.*cached reads:.*=[[:space:]]*//p' <<<"$line")"
    buffered="$(sed -n 's/^.*buffered disk reads:.*=[[:space:]]*//p' <<<"$line")"
    rotational="$(cat "/sys/block/$name/queue/rotational" 2>/dev/null)"
    show_one "cached reads" "${cached:-n/a}  (memory speed, not disk-specific)"
    show_one "buffered disk reads" "${buffered:-n/a}  ($(rate_buffered "${buffered%% *}" "$rotational"))"
  done < <(physical_disks)

  echo
  if [ "$found" = 0 ]; then
    warn "no physical disks found to benchmark"
  elif [ "$DRYRUN" != 1 ]; then
    info "hdparm under-reports SSDs (no queued I/O) -- treat \"slow for an SSD\" as a"
    info "hint to check link speed/cabling/load, not a hard diagnosis."
  fi
}

#==============================================================================
# Argument parsing & dispatch
#==============================================================================
usage() {
  sed -n '2,56p' "$SELF_REALPATH" | sed 's/^#\{0,1\} \{0,1\}//'
}

parse_args() {
  local a
  for a in "${ORIG_ARGS[@]}"; do
    case "$a" in
      --apply)      ACTION="apply" ;;
      --undo)       ACTION="undo" ;;
      --status)     ACTION="status" ;;
      --iobench)    ACTION="iobench" ;;
      --boot-apply) ACTION="boot-apply" ;;
      --dry-run|-n) DRYRUN=1 ;;
      --help|-h)    ACTION="help" ;;
      *) err "Unknown argument: $a"; echo "Try: $0 --help" >&2; exit 2 ;;
    esac
  done
}

main() {
  parse_args
  DESK_USER="$(detect_desktop_user)"

  case "$ACTION" in
    help)   usage ;;
    status) do_status ;;
    iobench)
      [ "$DRYRUN" = 1 ] || require_root
      do_iobench ;;
    boot-apply)
      require_root
      apply_runtime ;;        # quiet path used by the systemd unit at boot
    apply)
      [ "$DRYRUN" = 1 ] || require_root
      do_apply ;;
    undo)
      [ "$DRYRUN" = 1 ] || require_root
      do_undo ;;
    *) err "No action"; usage; exit 2 ;;
  esac
}

main
