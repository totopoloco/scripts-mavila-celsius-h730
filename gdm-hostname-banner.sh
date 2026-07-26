#!/usr/bin/env bash
#===============================================================================
# gdm-hostname-banner.sh
#
# Shows this machine's current hostname on the GDM login screen.
#
# WHY THIS EXISTS
#   GDM's login-screen banner (org.gnome.login-screen banner-message-text) is
#   a plain static string -- there is no "%H hostname" placeholder, no
#   template support at all. Typing the hostname into a config file by hand
#   would be a hardcoded literal that silently goes stale (this host's
#   hostname comes from DHCP, not a static /etc/hostname -- see /etc/hosts).
#   So instead of a fixed string, this script re-reads `hostname` and
#   regenerates the dconf drop-in from scratch, twice over (see MECHANISM):
#   once as GDM starts, and again the moment DHCP actually assigns the real
#   name. Nothing here is a value a human typed in and forgot about.
#
#   Gotcha this had to work around: gdm.service starts LONG before
#   NetworkManager finishes DHCP on this host (confirmed via journalctl --
#   NetworkManager sets the hostname to the 'localhost.localdomain' fallback
#   first, and only overwrites it with the real DHCP-assigned name ~5s
#   later, well after GDM is already up). A hook that only fires at GDM
#   start would forever capture that fallback, not the real hostname -- so a
#   second hook below reacts to the DHCP-driven change itself.
#
# MECHANISM
#   * GDM's greeter runs under its own "gdm" dconf profile (a system-db,
#     separate from any real user's dconf). /etc/dconf/profile/gdm wires
#     that profile to /etc/dconf/db/gdm.d/*.
#   * /etc/dconf/db/gdm.d/01-hostname-banner sets banner-message-enable=true
#     and banner-message-text='<current hostname>', regenerated on every run.
#     GNOME Shell's login dialog watches this key live, so rewriting it (via
#     either hook below) updates an already-visible greeter with no restart.
#   * /etc/systemd/system/gdm.service.d/hostname-banner.conf adds
#     `ExecStartPre=-<installed copy> --boot-apply`, re-deriving the banner
#     immediately before every GDM start -- correct right away for a static
#     hostname, a best-effort guess otherwise. The leading "-" tells systemd
#     to ignore this step's exit code, so a bug here can never block GDM
#     from starting and locking you out of a graphical login.
#   * /etc/NetworkManager/dispatcher.d/90-gdm-hostname-banner runs the same
#     regeneration on NetworkManager's "hostname" dispatch event -- the
#     precise moment DHCP (or any other source) actually changes the
#     hostname, however long after GDM already started that turns out to be.
#
# PERSISTENCE
#   Installed copy: /usr/local/sbin/gdm-hostname-banner.sh (run by both
#   hooks above; --undo removes it).
#
# USAGE
#   ./gdm-hostname-banner.sh [--apply]   # apply now + install the boot hook (needs root)
#   ./gdm-hostname-banner.sh --dry-run   # show what --apply would do
#   ./gdm-hostname-banner.sh --undo      # remove everything (needs root)
#   ./gdm-hostname-banner.sh --status    # compare configured vs. live hostname
#   ./gdm-hostname-banner.sh --help
#
#   Applying (or undoing) does NOT restart GDM -- your current graphical
#   session is untouched either way. The banner only appears after GDM next
#   starts: reboot, or `sudo systemctl restart gdm` (ends the active session
#   immediately), whenever you're ready.
#===============================================================================

set -uo pipefail

SELF_REALPATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

DCONF_PROFILE="/etc/dconf/profile/gdm"
DCONF_DROPIN_DIR="/etc/dconf/db/gdm.d"
DCONF_DROPIN="$DCONF_DROPIN_DIR/01-hostname-banner"
SYSTEMD_DROPIN_DIR="/etc/systemd/system/gdm.service.d"
SYSTEMD_DROPIN="$SYSTEMD_DROPIN_DIR/hostname-banner.conf"
DISPATCHER_SCRIPT="/etc/NetworkManager/dispatcher.d/90-gdm-hostname-banner"
INSTALLED_COPY="/usr/local/sbin/gdm-hostname-banner.sh"

DRYRUN=0
ACTION="apply"
ORIG_ARGS=("$@")

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DRY=$'\033[35m'; C_HDR=$'\033[1m'
else
  C_RST=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_DRY=""; C_HDR=""
fi
info() { printf '%s[*]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }
dry()  { printf '%s[dry-run]%s would %s\n' "$C_DRY" "$C_RST" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_HDR" "$*" "$C_RST"; }

write_managed_file() {
  local path="$1" mode="${2:-0644}" content; content="$(cat)"
  if [ "$DRYRUN" = 1 ]; then
    dry "write $path (mode $mode):"
    printf '%s\n' "$content" | sed 's/^/        | /'
    return 0
  fi
  install -d -m 0755 "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
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

dconf_profile_content() {
cat <<'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF
}

dconf_dropin_content() {
  local host; host="$(hostname)"
cat <<EOF
# Managed by gdm-hostname-banner.sh -- do not hand-edit, regenerated from the
# live hostname on every GDM start. Remove via: gdm-hostname-banner.sh --undo
[org/gnome/login-screen]
banner-message-enable=true
banner-message-text='$host'
EOF
}

systemd_dropin_content() {
cat <<EOF
# Managed by gdm-hostname-banner.sh -- do not hand-edit.
# Remove via: gdm-hostname-banner.sh --undo
[Service]
ExecStartPre=-$INSTALLED_COPY --boot-apply
EOF
}

dispatcher_content() {
cat <<EOF
#!/bin/sh
# Managed by gdm-hostname-banner.sh -- do not hand-edit.
# Remove via: gdm-hostname-banner.sh --undo
# NetworkManager calls every script here with "\$2 = hostname" the moment it
# actually changes the system hostname (e.g. once DHCP hands one out) --
# arbitrarily later than GDM's own start, hence this second hook.
[ "\$2" = "hostname" ] || exit 0
exec $INSTALLED_COPY --boot-apply
EOF
}

regenerate_banner() {
  local host; host="$(hostname)"
  hdr "GDM banner -> current hostname ($host)"

  if [ -e "$DCONF_PROFILE" ] && [ "$DRYRUN" != 1 ] \
     && [ "$(cat "$DCONF_PROFILE" 2>/dev/null)" != "$(dconf_profile_content)" ]; then
    warn "$DCONF_PROFILE already exists with different content -- leaving it alone."
    warn "expected content would have been:"
    dconf_profile_content | sed 's/^/    /'
  else
    dconf_profile_content | write_managed_file "$DCONF_PROFILE"
  fi

  dconf_dropin_content | write_managed_file "$DCONF_DROPIN"

  if [ "$DRYRUN" = 1 ]; then
    dry "run: dconf update"
  else
    dconf update && ok "dconf recompiled" || warn "dconf update reported errors"
  fi
}

do_apply() {
  regenerate_banner

  hdr "Boot hook: re-derive the banner from the live hostname before every GDM start"
  systemd_dropin_content | write_managed_file "$SYSTEMD_DROPIN"

  if [ "$DRYRUN" = 1 ]; then
    dry "install $SELF_REALPATH -> $INSTALLED_COPY (0755, root)"
    dry "run: systemctl daemon-reload"
  else
    install -m 0755 -o root -g root "$SELF_REALPATH" "$INSTALLED_COPY" \
      && ok "installed $INSTALLED_COPY"
    systemctl daemon-reload && ok "systemd reloaded"
  fi

  hdr "Network hook: re-derive the banner the moment DHCP sets the real hostname"
  dispatcher_content | write_managed_file "$DISPATCHER_SCRIPT" 0755

  hdr "Done"
  if [ "$DRYRUN" = 1 ]; then
    info "Dry run only -- nothing was changed."
  else
    ok "Banner's stored value corrected to: $(hostname)"
    info "Takes effect for any greeter from now on (lock screen, user switch, next boot) --"
    info "no GDM restart needed. Boot + DHCP hooks installed so future starts self-correct too."
    info "Check anytime with:  $0 --status"
    info "Revert with:         sudo $0 --undo"
  fi
}

do_undo() {
  hdr "Removing network hook"
  remove_file "$DISPATCHER_SCRIPT"

  hdr "Removing boot hook"
  remove_file "$SYSTEMD_DROPIN"
  if [ "$DRYRUN" = 1 ]; then
    dry "rmdir $SYSTEMD_DROPIN_DIR (if now empty)"
    dry "run: systemctl daemon-reload"
  else
    rmdir "$SYSTEMD_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload && ok "systemd reloaded"
  fi
  remove_file "$INSTALLED_COPY"

  hdr "Removing dconf banner config"
  remove_file "$DCONF_DROPIN"
  if [ "$DRYRUN" = 1 ]; then
    dry "rmdir $DCONF_DROPIN_DIR (if now empty)"
  else
    rmdir "$DCONF_DROPIN_DIR" 2>/dev/null || true
  fi
  remove_file "$DCONF_PROFILE"

  if [ "$DRYRUN" = 1 ]; then
    dry "run: dconf update"
    info "Dry run only -- nothing was changed."
  else
    dconf update && ok "dconf recompiled"
    ok "Banner config removed. Your current session is untouched;"
    info "the greeter drops the banner next time GDM starts (reboot, or"
    info "sudo systemctl restart gdm)."
  fi
}

show_one() { printf '  %-28s : %s\n' "$1" "$2"; }
do_status() {
  hdr "gdm-hostname-banner.sh status"
  local host; host="$(hostname)"
  show_one "live hostname" "$host"

  if [ -f "$DCONF_DROPIN" ]; then
    local configured
    configured="$(grep '^banner-message-text=' "$DCONF_DROPIN" | cut -d"'" -f2)"
    show_one "banner configured for" "${configured:-<not set>}"
    if [ "$configured" = "$host" ]; then
      show_one "in sync with live hostname" "yes"
    else
      show_one "in sync with live hostname" "no -- run --apply or reboot to refresh"
    fi
  else
    show_one "banner configured for" "(not configured -- run --apply)"
  fi

  show_one "dconf profile" "$( [ -f "$DCONF_PROFILE" ] && echo present || echo absent )"
  show_one "boot hook installed" "$( [ -f "$SYSTEMD_DROPIN" ] && echo present || echo absent )"
  show_one "DHCP/network hook installed" "$( [ -x "$DISPATCHER_SCRIPT" ] && echo present || echo absent )"
  show_one "installed copy" "$( [ -f "$INSTALLED_COPY" ] && echo "$INSTALLED_COPY" || echo absent )"

  local loaded
  loaded="$(systemctl show gdm.service -p ExecStartPre --value 2>/dev/null)"
  case "$loaded" in
    *"$INSTALLED_COPY"*) show_one "systemd sees the boot hook" "yes" ;;
    *)                   show_one "systemd sees the boot hook" "no" ;;
  esac
  echo
}

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
}

parse_args() {
  local a
  for a in "${ORIG_ARGS[@]}"; do
    case "$a" in
      --apply)      ACTION="apply" ;;
      --undo)       ACTION="undo" ;;
      --status)     ACTION="status" ;;
      --boot-apply) ACTION="boot-apply" ;;
      --dry-run|-n) DRYRUN=1 ;;
      --help|-h)    ACTION="help" ;;
      *) err "Unknown argument: $a"; echo "Try: $0 --help" >&2; exit 2 ;;
    esac
  done
}

main() {
  parse_args
  case "$ACTION" in
    help)   usage ;;
    status) do_status ;;
    boot-apply)
      require_root
      regenerate_banner ;;
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
