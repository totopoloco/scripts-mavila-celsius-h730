#!/usr/bin/env bash
#===============================================================================
# modernize-apt-sources.sh
#
# Moves this machine's third-party apt sources from the old one-line format
# (/etc/apt/sources.list.d/*.list) to the deb822 format (*.sources) and limits
# third-party sources to amd64. `apt modernize-sources` converts the format too,
# but it drops `arch=amd64`. Without it apt asks those servers for 32-bit (i386)
# package lists they don't have (Steam turns i386 on) and prints a notice.
#
# WHAT IT CHANGES (in /etc/apt/sources.list.d)
#   * Each .list file it can convert becomes a .sources file with the same
#     entries plus "Architectures: amd64". The .list file moves to the backup.
#     If a .sources file with that name already exists, the entries are added
#     at its end (pgadmin4.sources holds an old, disabled entry).
#   * Enabled entries in third-party .sources files that have no
#     Architectures line get "Architectures: amd64".
#
# WHAT IT LEAVES ALONE
#   * Ubuntu's own sources (*.ubuntu.com) and Steam's: Steam's 32-bit libraries
#     come from them, so they keep i386.
#   * Files that belong to a package (steam-*.list, synaptics.list,
#     protonvpn-stable.sources): dpkg would ask about them on the next upgrade.
#   * Files a package's install script writes again as .list, which would leave
#     every entry twice: spotify.list and scootersoftware.list (KEEP_AS_IS).
#   * Sources an installed 32-bit package comes from, .list files without
#     active entries, and disabled entries.
#   Because a few .list files stay, apt keeps printing "Some sources can be
#   modernized". That is expected.
#
# SAFETY
#   * The new files are first tried with a private `apt-get update` (its own
#     lists and cache in a temp folder; /etc/apt is not touched). Any error,
#     warning or notice stops the run before anything changes.
#   * Every file it replaces, edits or removes is first copied to
#     /var/backups/modernize-apt-sources/<date-time>/. --undo restores the
#     newest of those and moves the files this script created into it.
#
# USAGE
#   ./modernize-apt-sources.sh --dry-run          # show the changes and test them (no root needed)
#   ./modernize-apt-sources.sh                    # convert (needs root; re-runs itself with sudo)
#   ./modernize-apt-sources.sh --undo --dry-run   # show what --undo would restore
#   ./modernize-apt-sources.sh --undo             # restore the newest backup (needs root)
#   ./modernize-apt-sources.sh --help
#
#   Real runs log to modernize-apt-sources-YYYYmmdd-HHMMSS.log next to the script.
#===============================================================================

set -uo pipefail

SELF_REALPATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SELF_REALPATH")"
SRC_DIR="/etc/apt/sources.list.d"
BACKUP_ROOT="/var/backups/modernize-apt-sources"
ARCH="amd64"
STAMP="$(date +%Y%m%d-%H%M%S)"
NOW="$(date '+%F %R')"

# .list files that a package's install script deletes and writes again on every
# install or upgrade. Converted, they would come back next to the new .sources
# file, and apt would see every entry twice.
KEEP_AS_IS=(
  spotify.list          # spotify-client's postinst
  scootersoftware.list  # bcompare's postinst copies /usr/lib/beyondcompare/scootersoftware.list
)

DRYRUN=0
ACTION="apply"     # apply | undo | help
ORIG_ARGS=("$@")
WORK=""            # temp folder: staged files and the test's apt state
LOG_FILE=""
LOG_TEE_PID=""
I386_ORIGINS=""    # "<package> <uri>" per installed i386 package and source
CONVERT=()         # .list files to convert
EDIT=()            # .sources files that get an Architectures line
KEPT=()            # "<file>|<reason>" for files left alone

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

# Run a command, or just describe it in dry-run mode.
run() {
  if [ "$DRYRUN" = 1 ]; then dry "run: $*"; return 0; fi
  "$@"
}

on_exit() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  if [ -n "$LOG_FILE" ]; then
    exec >&- 2>&-
    if [ -n "$LOG_TEE_PID" ]; then wait "$LOG_TEE_PID" 2>/dev/null; fi
  fi
}
trap on_exit EXIT

start_log() {
  LOG_FILE="${SCRIPT_DIR}/modernize-apt-sources-${STAMP}.log"
  exec > >(tee "$LOG_FILE") 2>&1
  LOG_TEE_PID=$!
  info "Logging this run to: $LOG_FILE"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    info "Root privileges required; re-running with sudo..."
    exec sudo -- "$SELF_REALPATH" "${ORIG_ARGS[@]}"
  fi
}

#------------------------------------------------------------------------------
# Reading the sources
#------------------------------------------------------------------------------

# Prints the package that owns a file; fails if no package does.
owner_of() {
  local out
  out="$(dpkg-query -S "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${out%%:*}"
}

# Fills I386_ORIGINS from the sources that offer the installed version of each
# installed i386 package.
load_i386_origins() {
  local pk
  pk="$(dpkg-query -W -f='${Package}:${Architecture}\n' 2>/dev/null | grep ':i386$')" || return 0
  # shellcheck disable=SC2086  # one argument per package
  I386_ORIGINS="$(apt-cache policy $pk 2>/dev/null | awk '
    /^[^ ]/        { pkg = $1; sub(/:$/, "", pkg); inst = 0; next }
    /^ \*\*\* /    { inst = 1; next }
    /^     [^ ]/   { inst = 0; next }
    inst && $2 ~ /:\/\// { u = $2; sub(/\/+$/, "", u); print pkg, u }')"
}

# Prints how many installed i386 packages come from any of the given URIs.
i386_users_of() {
  if [ -z "$I386_ORIGINS" ] || [ "$#" -eq 0 ]; then echo 0; return; fi
  awk 'NR == FNR { sub(/\/+$/, ""); if ($0 != "") want[$0]; next }
       ($2 in want) && !($1 in seen) { seen[$1]; n++ }
       END { print n + 0 }' <(printf '%s\n' "$@") <(printf '%s\n' "$I386_ORIGINS")
}

# Prints the entries of a one-line-format .list file ($1) as deb822 stanzas
# with "Architectures: $ARCH", and writes their URIs to the file $2. Fails, with
# the reason on stderr, on anything it can't convert without changing what apt
# does.
list_to_deb822() {
  awk -v arch="$ARCH" -v urisfile="$2" '
    function fail(msg) { print msg > "/dev/stderr"; bad = 1; exit 1 }
    {
      sub(/\r$/, "")
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line == "" || line ~ /^#/) next
      sub(/[ \t]+#.*$/, "", line); sub(/[ \t]+$/, "", line)
      type = line; sub(/[ \t].*$/, "", type)
      rest = substr(line, length(type) + 1); sub(/^[ \t]+/, "", rest)
      if (type != "deb" && type != "deb-src") fail("line " NR ": unknown type \"" type "\"")
      opts = ""
      if (substr(rest, 1, 1) == "[") {
        p = index(rest, "]")
        if (!p) fail("line " NR ": no closing ]")
        opts = substr(rest, 2, p - 2)
        rest = substr(rest, p + 1); sub(/^[ \t]+/, "", rest)
      }
      n = split(rest, w, /[ \t]+/)
      if (n < 2) fail("line " NR ": no suite")
      archs = ""; key = ""
      m = split(opts, o, /[ \t]+/)
      for (i = 1; i <= m; i++) {
        if (o[i] == "") continue
        eq = index(o[i], "=")
        k = eq ? substr(o[i], 1, eq - 1) : o[i]
        v = substr(o[i], eq + 1)
        if (k == "arch") archs = v
        else if (k == "signed-by") key = v
        else fail("line " NR ": option \"" o[i] "\" is not handled by this script")
      }
      if (archs != "" && ("," archs ",") !~ ("," arch ",")) fail("line " NR ": arch=" archs " has no " arch)
      if (("," archs ",") ~ /,i386,/) fail("line " NR ": arch=" archs " includes i386")
      comps = ""
      for (i = 3; i <= n; i++) comps = comps (i > 3 ? " " : "") w[i]
      if (comps == "" && w[2] !~ /\/$/) fail("line " NR ": no components")
      if (out++) print ""
      print "Types: " type
      print "URIs: " w[1]
      print "Suites: " w[2]
      if (comps != "") print "Components: " comps
      print "Architectures: " arch
      if (key != "") print "Signed-By: " key
      print w[1] > urisfile
    }
    END {
      if (bad) exit 1
      if (!out) { print "no active entries" > "/dev/stderr"; exit 1 }
    }
  ' "$1"
}

# Prints the deb822 file $1 with "Architectures: $ARCH" added to every enabled
# third-party entry that has none (after its Components line), and writes the
# URIs of those entries to the file $2. Ubuntu's own entries keep i386.
add_arch() {
  : > "$2"
  awk -v arch="$ARCH" -v urisfile="$2" '
    function off(v) { v = tolower(v); gsub(/[ \t]/, "", v); return v ~ /^(no|false|0|off|without|disable)$/ }
    function flush(   i, at) {
      if (!n) return
      at = 0
      if (("types" in f) && ("uris" in f) && !("architectures" in f) && !off(f["enabled"]) \
          && f["uris"] !~ /:\/\/([^\/ ]*\.)?ubuntu\.com(\/| |$)/) {
        at = ("components" in end) ? end["components"] : (("suites" in end) ? end["suites"] : n)
        print f["uris"] > urisfile
      }
      for (i = 1; i <= n; i++) { print L[i]; if (i == at) print "Architectures: " arch }
      n = 0; split("", L); split("", f); split("", end); cur = ""
    }
    /^[ \t]*$/ { flush(); print; next }
    { L[++n] = $0 }
    /^#/ { next }
    /^[ \t]/ { if (cur != "") { f[cur] = f[cur] " " $0; end[cur] = n }; next }
    { p = index($0, ":"); if (p) { cur = tolower(substr($0, 1, p - 1)); f[cur] = substr($0, p + 1); end[cur] = n } }
    END { flush() }
  ' "$1"
}

# Succeeds if a one-line-format file has an active (not commented-out) line.
has_entries() {
  awk '!/^[[:space:]]*(#|$)/ { found = 1; exit } END { exit !found }' "$1"
}

in_keep_list() {
  local k
  for k in "${KEEP_AS_IS[@]}"; do [ "$k" = "$1" ] && return 0; done
  return 1
}

# Prints a file and makes sure it ends with a newline.
cat_nl() {
  cat "$1"
  if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then echo; fi
}

#------------------------------------------------------------------------------
# Plan: stage the new and changed files in $WORK/stage
#------------------------------------------------------------------------------
plan() {
  local f name pkg n target why
  WORK="$(mktemp -d)"; chmod 0755 "$WORK"
  mkdir -p "$WORK/stage"
  load_i386_origins

  # Existing .sources files: add the Architectures line where it's missing.
  for f in "$SRC_DIR"/*.sources; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    add_arch "$f" "$WORK/uris" > "$WORK/edited" || { warn "$name: could not read it; left alone"; continue; }
    cmp -s "$f" "$WORK/edited" && continue
    if pkg="$(owner_of "$f")"; then KEPT+=("$name|belongs to package $pkg"); continue; fi
    # shellcheck disable=SC2046  # one argument per URI
    n="$(i386_users_of $(cat "$WORK/uris"))"
    if [ "$n" -gt 0 ]; then KEPT+=("$name|$n installed 32-bit packages come from it"); continue; fi
    cp "$WORK/edited" "$WORK/stage/$name"
    EDIT+=("$name")
  done

  # .list files: convert them.
  for f in "$SRC_DIR"/*.list; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    target="${name%.list}.sources"
    if in_keep_list "$name"; then KEPT+=("$name|its package's install script writes it again"); continue; fi
    if pkg="$(owner_of "$f")"; then KEPT+=("$name|belongs to package $pkg"); continue; fi
    if [ -f "$SRC_DIR/$target" ] && pkg="$(owner_of "$SRC_DIR/$target")"; then
      KEPT+=("$name|$target belongs to package $pkg"); continue
    fi
    : > "$WORK/uris"
    if ! list_to_deb822 "$f" "$WORK/uris" > "$WORK/stanzas" 2> "$WORK/why"; then
      why="$(head -n1 "$WORK/why")"
      KEPT+=("$name|${why:-cannot convert it}"); continue
    fi
    # shellcheck disable=SC2046  # one argument per URI
    n="$(i386_users_of $(cat "$WORK/uris"))"
    if [ "$n" -gt 0 ]; then KEPT+=("$name|$n installed 32-bit packages come from it"); continue; fi
    {
      if [ -f "$WORK/stage/$target" ]; then cat_nl "$WORK/stage/$target"; echo
      elif [ -f "$SRC_DIR/$target" ]; then cat_nl "$SRC_DIR/$target"; echo
      fi
      echo "# Converted from $name by modernize-apt-sources.sh on $NOW."
      cat "$WORK/stanzas"
    } > "$WORK/new"
    mv "$WORK/new" "$WORK/stage/$target"
    CONVERT+=("$name")
  done
}

show_plan() {
  local name target k
  if [ "${#CONVERT[@]}" -gt 0 ]; then
    hdr "Convert to .sources, amd64 only (${#CONVERT[@]})"
    for name in "${CONVERT[@]}"; do
      target="${name%.list}.sources"
      if [ -f "$SRC_DIR/$target" ]; then
        info "$name -> added to the existing $target:"
        diff -u --label "$target (now)" --label "$target (new)" "$SRC_DIR/$target" "$WORK/stage/$target" \
          | tail -n +3 | sed 's/^/        /'
      else
        info "$name -> $target:"
        sed 's/^/        | /' "$WORK/stage/$target"
      fi
    done
  fi
  if [ "${#EDIT[@]}" -gt 0 ]; then
    hdr "Add \"Architectures: $ARCH\" (${#EDIT[@]})"
    for name in "${EDIT[@]}"; do
      info "$name:"
      diff -u --label "$name (now)" --label "$name (new)" "$SRC_DIR/$name" "$WORK/stage/$name" \
        | tail -n +3 | sed 's/^/        /'
    done
  fi
  if [ "${#KEPT[@]}" -gt 0 ]; then
    hdr "Left as they are (${#KEPT[@]})"
    for k in "${KEPT[@]}"; do info "${k%%|*}: ${k#*|}"; done
  fi
}

# Tries the staged files with a private apt-get update. Nothing in /etc/apt or
# /var/lib/apt is touched.
test_staged() {
  local t="$WORK/apt" rc problems
  mkdir -p "$t/parts" "$t/conf.d" "$t/lists/partial" "$t/cache/archives/partial"
  cp "$WORK/stage/"*.sources "$t/parts/"
  cat > "$t/apt.conf" <<EOF
Dir::Etc::Parts "$t/conf.d";
Dir::Etc::main "/dev/null";
Dir::Etc::SourceList "/dev/null";
Dir::Etc::SourceParts "$t/parts";
Dir::State::Lists "$t/lists";
Dir::Cache "$t/cache";
Acquire::Languages "none";
APT::Sandbox::User "root";
EOF
  info "Fetching the package lists of the new files into a temp folder..."
  APT_CONFIG="$t/apt.conf" apt-get -o quiet=0 update > "$t/out" 2>&1
  rc=$?
  problems="$(grep -E '^(E|W|N|Err):' "$t/out")"
  if [ "$rc" -ne 0 ] || [ -n "$problems" ]; then
    err "The test failed (apt-get exit code $rc); nothing was changed:"
    printf '%s\n' "${problems:-$(tail -n 20 "$t/out")}" | sed 's/^/        /' >&2
    return 1
  fi
  info "apt read every new file and fetched its lists without an error, warning or notice."
}

#------------------------------------------------------------------------------
# Apply and undo
#------------------------------------------------------------------------------
apply_staged() {
  local bk="$BACKUP_ROOT/$STAMP" kind name f
  run install -d -m 0755 "$bk"
  # The manifest comes first, so --undo works even if a later step fails.
  {
    for name in "${CONVERT[@]}"; do echo "saved $name"; done
    for f in "$WORK/stage/"*; do
      name="${f##*/}"
      if [ -e "$SRC_DIR/$name" ]; then echo "saved $name"; else echo "new $name"; fi
    done
  } > "$WORK/manifest"
  run cp "$WORK/manifest" "$bk/manifest"
  while read -r kind name; do
    if [ "$kind" = saved ]; then run cp -a "$SRC_DIR/$name" "$bk/$name" || return 1; fi
  done < "$WORK/manifest"
  ok "Backed up to $bk"

  for f in "$WORK/stage/"*; do
    name="${f##*/}"
    run install -m 0644 "$f" "$SRC_DIR/$name" || return 1
    ok "wrote $SRC_DIR/$name"
  done
  for name in "${CONVERT[@]}"; do
    run rm -f "$SRC_DIR/$name" || return 1
    ok "removed $SRC_DIR/$name (copy in the backup)"
  done
}

do_apply() {
  local k name left=()
  plan
  show_plan
  if [ "${#CONVERT[@]}" -eq 0 ] && [ "${#EDIT[@]}" -eq 0 ]; then
    info "Nothing to change."
    return 0
  fi

  hdr "Test"
  test_staged || exit 1
  if [ "$DRYRUN" = 1 ]; then
    info "Dry run: nothing was changed. Run it without --dry-run to apply."
    return 0
  fi

  hdr "Apply"
  if ! apply_staged; then
    err "Stopped part-way. Run: $0 --undo"
    exit 1
  fi

  hdr "apt-get update"
  if ! apt-get update; then
    err "apt-get update failed. To go back: $0 --undo"
    exit 1
  fi
  ok "Done. To go back: $0 --undo"
  # Only .list files with an active entry make apt print the notice.
  for k in "${KEPT[@]}"; do
    name="${k%%|*}"
    case "$name" in
      *.list) has_entries "$SRC_DIR/$name" && left+=("$name") ;;
    esac
  done
  if [ "${#left[@]}" -gt 0 ]; then
    info "apt keeps printing \"Some sources can be modernized\" because of: ${left[*]}"
  fi
}

do_undo() {
  local bk kind name
  bk="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '2*' ! -name '*-undone' 2>/dev/null | sort | tail -n1)"
  if [ -z "$bk" ] || [ ! -f "$bk/manifest" ]; then
    err "No backup to restore in $BACKUP_ROOT."
    exit 1
  fi
  hdr "Undo: restore $bk"
  while read -r kind name; do
    case "$kind" in
      new)
        if [ -e "$SRC_DIR/$name" ]; then
          run install -d -m 0755 "$bk/undone"
          run mv "$SRC_DIR/$name" "$bk/undone/" && ok "moved $SRC_DIR/$name to $bk/undone/"
        fi ;;
      saved)
        run cp -a "$bk/$name" "$SRC_DIR/$name" && ok "restored $SRC_DIR/$name" ;;
    esac
  done < "$bk/manifest"
  run mv "$bk" "$bk-undone"
  if [ "$DRYRUN" = 1 ]; then
    info "Dry run: nothing was changed."
    return 0
  fi
  hdr "apt-get update"
  apt-get update || { err "apt-get update failed after the undo."; exit 1; }
  ok "Restored. The backup is now $bk-undone."
}

#==============================================================================
# Argument parsing & dispatch
#==============================================================================
usage() {
  awk 'NR > 2 && /^#=+$/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$SELF_REALPATH"
}

parse_args() {
  local a
  for a in "${ORIG_ARGS[@]}"; do
    case "$a" in
      --undo)       ACTION="undo" ;;
      --dry-run|-n) DRYRUN=1 ;;
      --help|-h)    ACTION="help" ;;
      *) err "Unknown argument: $a"; echo "Try: $0 --help" >&2; exit 2 ;;
    esac
  done
}

main() {
  parse_args
  case "$ACTION" in
    help) usage; return 0 ;;
  esac
  if [ "$DRYRUN" != 1 ]; then
    require_root
    start_log
  fi
  case "$ACTION" in
    apply) do_apply ;;
    undo)  do_undo ;;
  esac
}

main
