#!/usr/bin/env bash
#
# hplip-from-hp.sh
#
# Installs HPLIP, HP's printing and scanning software with HP Device Manager,
# built from HP's own signed hplip-<version>.run, so that Ubuntu's updates
# can't undo it. Written for HPLIP 3.26.6 on Ubuntu 26.04 and this machine's
# HP Color LaserJet Pro MFP 3302 (networked, needs no HP plugin). A newer .run
# from sourceforge.net/projects/hplip should go through the same way.
#
# Why neither Ubuntu's HPLIP nor HP's installer:
# - Ubuntu 26.04 ships HPLIP 3.24.4. Its Device Manager can crash on the
#   Supplies tab of a fax entry ("'Device' object has no attribute
#   'raw_deviceID'"): only a successful open() sets that attribute, and the
#   fax query reads it anyway. 3.26.6 sets it in Device.__init__.
# - HP's installer has no entry for 26.04 (its list stops at 24.04), and what
#   it installs doesn't last: Ubuntu's hplip-data, printer-driver-hpcups and
#   printer-driver-postscript-hp own the same paths, and libhpmud0's copy in
#   /usr/lib/x86_64-linux-gnu wins over HP's in /usr/lib. The 26.04 upgrade
#   put all four back over the 3.25.2 HP's installer set up in April 2025.
# - Ubuntu's 3.24.4 doesn't know the MFP 3302 at all: its models.dat (which
#   belongs to libsane-hpaio) has no entry, so Device Manager finds no device.
#   Until 2026-10-07 a leftover models.dat from HP's 3.25.2 hid that.
# - HP's own Python code isn't ready for 26.04: 3.26.6 still subclasses
#   urllib's URLopener (removed in Python 3.14), its scripts start with
#   '#!/usr/bin/env python' (26.04 has no python command), and it lacks the
#   Python fixes Ubuntu carries in debian/patches. Installed as HP ships it,
#   none of its tools started (found the hard way on 2026-10-07).
#
# Steps of --apply:
#    1. Checks the .run's GPG signature. The .asc comes from SourceForge and
#       the key from keyserver.ubuntu.com; the key's fingerprint is pinned
#       below (HP_KEY_FPR), so neither download can slip in another key.
#    2. Unpacks the source (tail | tar; nothing in the .run runs) into
#       ~/Downloads/hp_installation/hplip-<version>/, the folder HP's
#       installer uses. Keep it: --undo runs 'make uninstall' there. Then
#       ports it to 26.04 the way Ubuntu's packaging does: applies Ubuntu's
#       Python patches (UBUNTU_PATCHES below, SHA-256-pinned, from Ubuntu's
#       hplip 3.24.4+dfsg0-0ubuntu8.1) and points the scripts at python3.
#    3. Builds it as you, with HP's configure options for Ubuntu plus the
#       compiler flags GCC 14 and later need for HPLIP's C (CC_COMPAT below).
#    4. Tries the build before installing anything, as you and against your
#       printer, using the build's own code, data and compiled modules: a
#       tool must start, each hp: queue's model must be in the build's
#       models.dat, and its supplies and each fax queue are queried.
#       Any failure stops the script here, with nothing changed.
#    5. Builds hplip-from-hp, an empty local package that depends on the
#       libraries the build links against and the Python modules HPLIP uses,
#       and conflicts with Ubuntu's HPLIP packages.
#    6. Shows what apt will do and asks. Nothing has changed until here.
#    7. (sudo) Backs up HPLIP's files and config, and CUPS's printer config,
#       to /var/backups/hplip-from-hp/<timestamp>/.
#    8. (sudo) Installs hplip-from-hp, which removes Ubuntu's HPLIP packages.
#    9. (sudo) Pins Ubuntu's HPLIP packages to -1, so no update installs them
#       again, release upgrades included.
#   10. (sudo) make install and ldconfig, restarts CUPS; restarts the tray icon.
#   11. Checks the installed result the same way.
# Step 5 is what keeps update.sh's unattended autoremove away from those
# libraries: nothing else tells apt that HP's files need them.
#
# After a release upgrade, run this again: the new Python can't load modules
# built for the old one, and the upgrade removes hplip-from-hp because it
# depends on the old Python. The pin keeps Ubuntu's packages out meanwhile.
#
# Never purge libsane-hpaio. Ubuntu's package is gone, but dpkg still counts
# /etc/hp/hplip.conf as one of its config files, and a purge deletes it.
#
# A real --apply or --undo is logged to hplip-from-hp-YYYYmmdd-HHMMSS.log next
# to this script; the compiler's output goes to build.log in the build folder.
#
# Usage:
#   ./hplip-from-hp.sh                # --apply with the newest ~/Downloads/hplip-<version>.run
#   ./hplip-from-hp.sh --run FILE     # use this .run instead
#   ./hplip-from-hp.sh --dry-run      # steps 1-5 in a temp dir and step 6's plan, then print steps 7-10
#   ./hplip-from-hp.sh -n             # same as --dry-run
#   ./hplip-from-hp.sh --status       # what's installed and where it came from; no sudo
#   ./hplip-from-hp.sh --undo         # back to Ubuntu's hplip and hplip-gui (asks first)
#   ./hplip-from-hp.sh -h | --help
#
set -uo pipefail

DRY_RUN=0
ACTION="apply"
RUN=""

# HPLIP (HP Linux Imaging and Printing) <hplip@hp.com>: rsa2048 primary key
# created 2025-06-27, which signed hplip-3.26.6.run with subkey
# 5E4E4D24A34ECD57. Ubuntu's hplip-data only ships HP's old 2009 DSA key.
# Compare with developers.hp.com/hp-linux-imaging-and-printing/hplipDigitalCertificate.html
HP_KEY_FPR="82FFA7C6AA7411D934BDE173AC69536A2CF3A243"
KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${HP_KEY_FPR}"

BUILD_ROOT="$HOME/Downloads/hp_installation"
BACKUP_ROOT=/var/backups/hplip-from-hp
PIN_FILE=/etc/apt/preferences.d/hplip-from-hp.pref
HPLIP_CONF=/etc/hp/hplip.conf
DEVICE_PY=/usr/share/hplip/base/device.py
MARKER=hplip-from-hp
STAMP=.made-by-hplip-from-hp      # in a build folder this script created

# Every binary package Ubuntu builds from its hplip source package.
UBUNTU_PKGS=(hplip hplip-data hplip-gui hplip-doc hpijs-ppds libhpmud0 libhpmud-dev
             libsane-hpaio printer-driver-hpcups printer-driver-hpijs
             printer-driver-postscript-hp)

# What HP's installer ran for Ubuntu 24.04 (3.25.2's config.log, 2025-04-23),
# minus --disable-policykit, which 3.26.6's configure no longer knows.
CONFIGURE_FLAGS=(--prefix=/usr --libdir=/usr/lib --with-hpppddir=/usr/share/ppd/HP
                 --enable-network-build --enable-scan-build --enable-fax-build
                 --enable-dbus-build --disable-qt4 --enable-qt5 --disable-class-driver
                 --enable-doc-build --disable-libusb01_build --disable-udev_sysfs_rules
                 --enable-hpcups-install --disable-hpijs-install
                 --disable-foomatic-ppd-install --disable-foomatic-drv-install
                 --disable-cups-ppd-install --enable-cups-drv-install)

# The flags ride on CC because HPLIP's configure overwrites CFLAGS with
# python3-config's output (configure.in:631), and 'make CFLAGS=...' would drop
# the -DCONFDIR its Makefile appends. -std=gnu17 because GCC 15 compiles C23,
# where 'int f();' means "no arguments" and clashes with HPLIP's definitions.
# Each -Wno-error turns an error GCC 14 introduced back into a warning. All of
# 3.26.6's cases were checked on 2026-10-06: each is ABI-safe (the undeclared
# functions return int or void) or in code this printer never runs (ORBLITE
# scanners, and the Python 2 pcardext module, which never loads on Python 3).
CC_COMPAT="gcc -std=gnu17 -Wno-error=implicit-function-declaration -Wno-error=return-mismatch -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-int"

# What Ubuntu's hplip, hplip-data and hplip-gui depend on besides shared
# libraries; the libraries come from the build itself (lib_packages).
MARKER_DEPENDS="cups, cups-filters | ghostscript-cups, python3-dbus, python3-gi, python3-pexpect, python3-pil, python3-distro, python3-pyqt5, python3-dbus.mainloop.pyqt5, wget, xz-utils"
MARKER_RECOMMENDS="avahi-daemon, polkitd, pkexec, sane-utils, python3-notify2"

# Ubuntu's Python fixes for HPLIP, name:sha256, from debian/patches of Ubuntu's
# hplip 3.24.4+dfsg0-0ubuntu8.1, fetched at that version's git tag so the
# content can't change. All eight apply cleanly to 3.26.6 (2026-10-07), and
# with them its Device Manager, tray icon, hp-levels and fax query work on
# Python 3.14. Left out: 0086 (raw strings) only silences SyntaxWarnings and
# no longer applies.
PATCH_BASE="https://git.launchpad.net/ubuntu/+source/hplip/plain/debian/patches"
PATCH_TAG="applied/3.24.4%2Bdfsg0-0ubuntu8.1"
UBUNTU_PATCHES=(
  "hplip-no-urlopener:3380582b391b6959ddf20472ab55ea75df0b793033ee35cffdb17326661cd063"
  "0012-Treat-logging-before-importing-of-logger-module:3fe50b0f6576e573c5c288c2b740a19935ef68481415c1e9a131bd5b0ecdd726"
  "0026-Fix-handling-of-unicode-filenames-in-sixext.py:98e15d2fa7618bf18c0386d18810669dea5b5d38b684c071ab33ea585e7ec95c"
  "0029-Call-QMessageBox-constructors-of-PyQT5-with-the-corr:9af70fbc81b117b6d0dcf8b8f4e23096bf84e388a264b67b74fe746f1c66e532"
  "0061-hp-setup-fails-on-fax-setup-use-binary-strings:014420e4462c29f17d3b360be27777960897fbe8e7d64dbbd2094b2bc53010ec"
  "0074-py3.8-Fix-SyntaxWarning-is-is-not-with-a-literal:5e2ebc8a4e6f181ab88e1eb5d5131be3128db5d7dba13b836428cb6c6c8266b3"
  "0075-py3.8-Assume-the-python3-distro-package-is-available:2528976eb30ea718e0a3af1c669ff27ad198887fcf8671dc95a18892d05424ec"
  "0089-correct-invalid-escapes:dd2a3461e7c0ce2c92374c784243ba22db4535591cb3d574763892c2fbb2e5ce"
)

# Python snippets run against the installed HPLIP or a build. sys.argv[1] is
# the device URI. MODEL_PY prints the model's status-type from models.dat (0
# if the model isn't there, and then Device Manager lists no device); FAX_PY
# runs the query that crashed 3.24.4's Supplies tab on a fax entry.
MODEL_PY='import sys
from base import device
mq = device.queryModelByURI(sys.argv[1])
print(int(mq.get("status-type", 0) or 0))'
FAX_PY='import sys
from base import device
d = device.Device(sys.argv[1])
d.queryDevice()
print("status:", d.dq.get("status-desc"))
d.close()'

# make install's hook writes these outside DESTDIR, and make uninstall leaves
# them behind.
HOOK_FILES=(/usr/lib/libImageProcessor-x86_64.so /usr/lib/libImageProcessor.so
            /usr/share/ipp-usb/quirks/HPLIP.conf
            /usr/lib/x86_64-linux-gnu/sane/libsane-hpaio.so
            /usr/lib/x86_64-linux-gnu/sane/libsane-hpaio.so.1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=""
LOG_FILE=""
LOG_TEE_PID=""
VERSION=""        # of the .run being installed (or, under --undo, of the installed build)
BUILD_DIR=""      # $BUILD_ROOT/hplip-$VERSION
SRC_DIR=""        # where steps 2-4 happen: BUILD_DIR, or a temp dir under --dry-run
MARKER_DEB=""
BACKUP_DIR=""
PREV_VERSION=""   # an older build of this script's that --apply replaces
PREV_BUILD=""

while (( $# )); do
  case "$1" in
    --apply)      ACTION="apply" ;;
    --undo)       ACTION="undo" ;;
    --status)     ACTION="status" ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --run)        RUN="${2:-}"; shift ;;
    --run=*)      RUN="${1#--run=}" ;;
    -h|--help)
      sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 2
      ;;
  esac
  shift
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

# Same for a command that runs as you.
run_user() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "   ${c_ylw}[dry-run]${c_rst} $*"
  else
    "$@"
  fi
}

# run_logged FILE CMD...: run, with the command's output going to FILE.
run_logged() {
  local out="$1"
  shift
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "   ${c_ylw}[dry-run]${c_rst} sudo $*  > ${out}"
    return 0
  fi
  # shellcheck disable=SC2024  # the log is yours; only the command needs root
  if ! sudo "$@" >"$out" 2>&1; then
    err "'$*' failed. The end of ${out}:"
    tail -n 15 "$out" | show
    return 1
  fi
}

# confirm QUESTION: true if you answer y. Under --dry-run it only says what it
# would ask.
confirm() {
  local answer
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "   ${c_ylw}[dry-run]${c_rst} would ask: $1 [y/N]"
    return 0
  fi
  read -r -p "    $1 [y/N] " answer </dev/tty || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
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

need() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "$cmd is required but not installed."
      exit 1
    fi
  done
}

# conf_version: the version in /etc/hp/hplip.conf, which is what HPLIP says it is.
conf_version() { sed -n 's/^version=//p' "$HPLIP_CONF" 2>/dev/null | head -n 1; }

# code_owner: the package that owns HPLIP's Python code; empty for HP's build.
code_owner() { dpkg -S "$DEVICE_PY" 2>/dev/null | head -n 1 | cut -d: -f1; }

# shellcheck disable=SC2016  # ${...} is dpkg-query's format syntax, not the shell's
pkg_installed() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ?[iUFHWt]* ]]; }

# shellcheck disable=SC2016
pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }

installed_ubuntu_pkgs() {
  local p
  for p in "${UBUNTU_PKGS[@]}"; do
    if pkg_installed "$p"; then echo "$p"; fi
  done
}

# pin_active: apt has no candidate left for Ubuntu's HPLIP packages. (Not
# 'apt-cache | grep -q': grep quits at the match, apt-cache dies of SIGPIPE,
# and pipefail turns the match into a failure.)
pin_active() { [[ "$(LC_ALL=C apt-cache policy hplip-data 2>/dev/null)" == *"Candidate: (none)"* ]]; }

# A first line that runs a bare python, which Ubuntu 26.04 doesn't have.
BARE_PYTHON_RE='^#!(/usr/bin/env +|/usr/bin/)python( .*)?$'

# bare_python_scripts PATH...: the readable files under PATH that start with one.
bare_python_scripts() {
  local f first
  while IFS= read -r -d '' f; do
    [[ -r "$f" ]] || continue
    IFS= read -r first < "$f" || continue
    if [[ "$first" =~ $BARE_PYTHON_RE ]]; then echo "$f"; fi
  done < <(find "$@" -type f -print0 2>/dev/null)
}

# hp_queues: "queue uri" for each CUPS queue on HPLIP's hp: or hpfax: backend.
hp_queues() {
  LC_ALL=C lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\): \(hp\(fax\)\{0,1\}:.*\)$/\1 \2/p'
}

# supply_summary: hp-levels' output on stdin -> "Black 10%, Cyan 10%, ...".
supply_summary() {
  sed 's/\x1b\[[0-9;]*m//g' \
    | awk '/cartridge$/ {name = $1}
           /approx\./ {match($0, /approx\. *[0-9]+%/); p = substr($0, RSTART + 8, RLENGTH - 8)
                       gsub(/ /, "", p); out = out (out ? ", " : "") name " " p}
           END {print out}'
}

# installed_status_type URI: MODEL_PY against the installed HPLIP.
installed_status_type() {
  (cd / && timeout 60 python3 -W ignore -c "import sys; sys.path.insert(0, '/usr/share/hplip')
$MODEL_PY" "$1" </dev/null 2>/dev/null | tail -n 1)
}

# hplip_libhpmud: the libhpmud HPLIP's Python modules load, as a real path.
hplip_libhpmud() {
  local p
  p="$(ldd /usr/lib/python3/dist-packages/hpmudext.so 2>/dev/null | awk '$1 == "libhpmud.so.0" {print $3}')"
  [[ -n "$p" ]] && readlink -f "$p"
}

# fax_fix_present: HPLIP's Device class sets raw_deviceID in __init__ (3.26.6
# and later), so a fax entry's Supplies tab can't crash on it.
fax_fix_present() {
  awk '/^    def / {m = $2; sub(/\(.*/, "", m)}
       m == "__init__" && /self\.raw_deviceID *= / {found = 1}
       END {exit !found}' "$DEVICE_PY" 2>/dev/null
}

# modules_load: HPLIP's compiled Python modules import (they don't survive a
# change of Python version). Run from / so nothing in the cwd shadows them.
modules_load() { (cd / && python3 -c 'import cupsext, hpmudext, scanext') >/dev/null 2>&1; }

# run_version FILE: the HPLIP version in a .run's makeself label.
run_version() {
  head -c 4096 "$1" 2>/dev/null \
    | sed -n 's/^label="HPLIP \([0-9][0-9.]*\) Self Extracting Archive"$/\1/p'
}

newest_run() {
  local f
  f="$(printf '%s\n' "$HOME"/Downloads/hplip-[0-9]*.run | grep -v -- '-plugin\.run$' | sort -V | tail -n 1)"
  [[ -f "$f" ]] && echo "$f"
}

# --- steps 1-4: verify, unpack, build (as you) ------------------------------

# find_run: RUN, or the newest ~/Downloads/hplip-<version>.run; sets VERSION
# and BUILD_DIR.
find_run() {
  [[ -n "$RUN" ]] || RUN="$(newest_run)"
  if [[ -z "$RUN" || ! -f "$RUN" ]]; then
    err "No HPLIP installer found${RUN:+ at $RUN}. Download hplip-<version>.run from"
    err "  https://sourceforge.net/projects/hplip/files/hplip/"
    err "into ~/Downloads, or pass --run FILE."
    exit 1
  fi
  RUN="$(realpath -s "$RUN")"
  VERSION="$(run_version "$RUN")"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "$RUN doesn't look like an HPLIP installer (no 'HPLIP <version>' label in its header)."
    exit 1
  fi
  BUILD_DIR="$BUILD_ROOT/hplip-$VERSION"
}

# Step 1. gpg runs with a throwaway home inside WORK, so your keyring is
# untouched. Trust comes from HP_KEY_FPR alone: VALIDSIG's last field is the
# fingerprint of the primary key that made the signature.
verify_signature() {
  local asc="$WORK/hplip-$VERSION.run.asc" status primary
  log "1. Checking the signature of $(basename "$RUN")..."
  if [[ -f "$RUN.asc" ]]; then
    cp "$RUN.asc" "$asc"
  elif ! curl -fsSL --retry 3 -o "$asc" \
         "https://sourceforge.net/projects/hplip/files/hplip/${VERSION}/hplip-${VERSION}.run.asc/download"; then
    err "Could not download hplip-${VERSION}.run.asc from SourceForge."
    exit 1
  fi
  if ! grep -q -- '-----BEGIN PGP SIGNATURE-----' "$asc"; then
    err "What SourceForge sent as hplip-${VERSION}.run.asc is not a signature."
    exit 1
  fi
  if ! curl -fsSL --retry 3 -o "$WORK/hp-key.asc" "$KEY_URL"; then
    err "Could not download HP's signing key from keyserver.ubuntu.com."
    exit 1
  fi
  mkdir -m 700 "$WORK/gnupg"
  GNUPGHOME="$WORK/gnupg" gpg --batch --quiet --import "$WORK/hp-key.asc" >/dev/null 2>&1
  status="$(GNUPGHOME="$WORK/gnupg" gpg --batch --status-fd 1 --verify "$asc" "$RUN" 2>/dev/null)"
  primary="$(awk '$2 == "VALIDSIG" {print $NF}' <<<"$status")"
  if [[ "$primary" != "$HP_KEY_FPR" ]] \
     || grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY)' <<<"$status"; then
    err "The signature doesn't check out against HP's key ${HP_KEY_FPR}:"
    grep -E '^\[GNUPG:\] (GOODSIG|VALIDSIG|BADSIG|ERRSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY)' <<<"$status" | show
    exit 1
  fi
  ok "Good signature by HPLIP <hplip@hp.com>, made $(awk '$2 == "VALIDSIG" {print $4}' <<<"$status")"
}

# The build folder must be new or one this script made; anything else in
# hp_installation (HP's installer leaves its own hplip-<version> folders there)
# is never touched.
prepare_build_dir() {
  if [[ -e "$BUILD_DIR" && ! -f "$BUILD_DIR/$STAMP" ]]; then
    err "$BUILD_DIR exists and wasn't made by this script. Move it aside and run this again."
    exit 1
  fi
  if ! { rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR" && touch "$BUILD_DIR/$STAMP"; }; then
    err "Can't create $BUILD_DIR."
    exit 1
  fi
}

# Step 2. The .run is a makeself shell header followed by a gzipped tar that
# starts after line N, where the header's own unpacker says
# offset=`head -n N "$1" | wc -c`. Same arithmetic, without running the header.
unpack_source() {
  local dest="$1" lines bytes magic
  log "2. Unpacking the source into ${dest}/ (nothing from the installer runs)..."
  # shellcheck disable=SC2016  # matching the header's literal text
  lines="$(head -c 65536 "$RUN" | grep -a -m 1 -oE 'offset=`head -n [0-9]+ "\$1"' \
           | sed -E 's/.*head -n ([0-9]+).*/\1/')"
  if [[ ! "$lines" =~ ^[0-9]+$ ]]; then
    err "Can't find where the archive starts inside $(basename "$RUN")."
    exit 1
  fi
  bytes="$(head -n "$lines" "$RUN" | wc -c)"
  magic="$(tail -c +"$((bytes + 1))" "$RUN" | head -c 2 | od -An -tx1 | tr -d ' \n')"
  if [[ "$magic" != 1f8b ]]; then
    err "$(basename "$RUN") has no gzip archive where its header says (found '$magic' at byte $bytes)."
    exit 1
  fi
  mkdir -p "$dest"
  if ! tail -c +"$((bytes + 1))" "$RUN" | tar -xzf - -C "$dest" || [[ ! -x "$dest/configure" ]]; then
    err "Could not unpack the HPLIP source from $(basename "$RUN")."
    exit 1
  fi
  ok "Unpacked $(find "$dest" -type f | wc -l) files"
}

# Ubuntu's Python patches, each checked against its pinned SHA-256. One that HP
# has already absorbed (it applies in reverse) is skipped; one that fits
# neither way stops the script before anything changes.
apply_ubuntu_patches() {
  local dir="$1" entry name sum file applied=0 absorbed=0
  mkdir -p "$WORK/patches"
  for entry in "${UBUNTU_PATCHES[@]}"; do
    name="${entry%:*}"
    sum="${entry##*:}"
    file="$WORK/patches/$name.patch"
    if ! curl -fsSL --retry 3 -o "$file" "${PATCH_BASE}/${name}.patch?h=${PATCH_TAG}"; then
      err "Could not download Ubuntu's patch $name from git.launchpad.net."
      exit 1
    fi
    if [[ "$(sha256sum < "$file" | cut -d' ' -f1)" != "$sum" ]]; then
      err "Ubuntu's patch $name doesn't have the expected SHA-256."
      exit 1
    fi
    if (cd "$dir" && patch -p1 -F3 -s --dry-run < "$file") >/dev/null 2>&1; then
      if ! (cd "$dir" && patch -p1 -F3 -s --no-backup-if-mismatch < "$file") >/dev/null 2>&1; then
        err "Applying Ubuntu's patch $name failed."
        exit 1
      fi
      applied=$((applied + 1))
    elif (cd "$dir" && patch -p1 -R -F3 -s --dry-run < "$file") >/dev/null 2>&1; then
      absorbed=$((absorbed + 1))
    else
      err "Ubuntu's patch $name doesn't fit HPLIP $VERSION, so nothing gets installed."
      err "A newer HPLIP may need UBUNTU_PATCHES in this script reworked."
      exit 1
    fi
  done
  if (( absorbed )); then
    ok "Applied $applied of Ubuntu's Python patches; $absorbed are already in HP's code"
  else
    ok "Applied Ubuntu's $applied Python patches"
  fi
}

# Point HP's Python scripts at python3, the way Ubuntu's own packaging does.
fix_shebangs() {
  local f n=0
  while IFS= read -r f; do
    sed -i -E '1s@^#!(/usr/bin/env +|/usr/bin/)python( |$)@#!/usr/bin/python3\2@' "$f" && n=$((n + 1))
  done < <(bare_python_scripts "$1")
  if (( n )); then
    ok "Pointed $n scripts from a bare 'python' to python3 (26.04 has no python command)"
  else
    ok "Its scripts already name python3"
  fi
}

configure_source() {
  if ! (cd "$1" && ./configure CC="$CC_COMPAT" "${CONFIGURE_FLAGS[@]}") >"$1/build.log" 2>&1; then
    err "configure failed. The end of $1/build.log:"
    tail -n 15 "$1/build.log" | show
    exit 1
  fi
}

# Step 3, as you. All compiler output goes to build.log in the folder.
build_source() {
  local dir="$1" t0=$SECONDS
  log "3. Building HPLIP $VERSION (about a minute; output in ${dir}/build.log)..."
  configure_source "$dir"
  if ! make -C "$dir" -j"$(nproc)" >>"$dir/build.log" 2>&1; then
    err "The build failed. Its errors:"
    grep -E 'error:|Error [0-9]+' "$dir/build.log" | head -n 15 | show
    exit 1
  fi
  ok "Built in $((SECONDS - t0)) s with $(grep -c 'warning:' "$dir/build.log") compiler warnings (see build.log)"
}

# A runner that starts an HPLIP script, or a snippet (-c CODE), from a build
# tree with that tree's code and data (models.dat), instead of what
# /etc/hp/hplip.conf points at.
write_runner() {
  cat > "$WORK/run_from_build.py" <<'EOF'
import os, runpy, sys
build = os.path.realpath(sys.argv[1])
sys.path.insert(0, build)
from base import g
for name, sub in (("home_dir", ""), ("data_dir", "data"), ("image_dir", "data/images"),
                  ("xml_dir", "data/xml"), ("models_dir", "data/models"),
                  ("localization_dir", "data/localization")):
    setattr(g.prop, name, os.path.join(build, sub) if sub else build)
if sys.argv[2] == "-c":
    code = sys.argv[3]
    sys.argv = ["-c"] + sys.argv[4:]
    exec(code, {"__name__": "__main__"})
else:
    script = os.path.join(build, sys.argv[2])
    sys.argv = [script] + sys.argv[3:]
    runpy.run_path(script, run_name="__main__")
EOF
}

# from_build DIR ARGS...: the runner, with the build's compiled modules.
from_build() {
  local dir="$1"
  shift
  (cd / && PYTHONPATH="$dir/.libs" LD_LIBRARY_PATH="$dir/.libs" \
     timeout 60 python3 -W ignore "$WORK/run_from_build.py" "$dir" "$@" </dev/null)
}

# Step 4: try the build before installing anything; any failure stops here.
smoke_test() {
  local dir="$1" out q uri st levels n=0
  log "4. Trying the build before installing anything (as you; this queries your printer)..."
  write_runner
  if ! out="$(from_build "$dir" levels.py -h 2>&1)"; then
    err "HPLIP $VERSION's tools don't start under $(python3 -V), so nothing gets installed:"
    tail -n 4 <<<"$out" | show
    exit 1
  fi
  ok "Its tools start under $(python3 -V)"
  while read -r q uri; do
    n=$((n + 1))
    if [[ "$uri" == hp:* ]]; then
      st="$(from_build "$dir" -c "$MODEL_PY" "$uri" 2>/dev/null | tail -n 1)"
      if [[ ! "$st" =~ ^[1-9][0-9]*$ ]]; then
        err "HPLIP $VERSION's models.dat doesn't know $q (${uri%%\?*}), so nothing gets installed."
        exit 1
      fi
      ok "It knows the model of $q"
      levels="$(from_build "$dir" levels.py -d "$uri" 2>&1 | supply_summary)"
      if [[ -n "$levels" ]]; then ok "It reads $q's supplies: $levels"
      else warn "It couldn't read $q's supplies (is the printer on?)"; fi
    else
      if out="$(from_build "$dir" -c "$FAX_PY" "$uri" 2>&1)" && [[ "$(tail -n 1 <<<"$out")" == status:* ]]; then
        ok "It queries the fax $q without crashing ($(tail -n 1 <<<"$out"))"
      else
        warn "Querying the fax $q failed:"
        tail -n 2 <<<"$out" | show
      fi
    fi
  done < <(hp_queues)
  (( n )) || warn "No CUPS queue uses HPLIP's hp: or hpfax: backend, so only the start-up was tried"
}

# tools_start: the installed hp-levels starts, first line and imports included.
tools_start() { timeout 30 hp-levels -h >/dev/null 2>&1; }

# lib_packages DIR: the packages providing the shared libraries the build
# links against, leaving out HPLIP's own (libhpmud, libhpip, libhpipp,
# libhpdiscovery, and HP's prebuilt libImageProcessor).
lib_packages() {
  local dir="$1" f so path pkg
  local -A pkgs=()
  while IFS= read -r -d '' f; do
    readelf -h "$f" >/dev/null 2>&1 || continue
    while read -r so; do
      [[ "$so" =~ ^lib(hpmud|hpip|hpipp|hpdiscovery|ImageProcessor)\. ]] && continue
      path="$(ldconfig -p | awk -v s="$so" '$1 == s && /x86-64/ {print $NF; exit}')"
      pkg=""
      [[ -n "$path" ]] && pkg="$(dpkg -S "$(readlink -f "$path")" 2>/dev/null | head -n 1 | cut -d: -f1)"
      if [[ -z "$pkg" ]]; then
        err "No installed package provides $so, which ${f#"$dir"/} needs."
        return 1
      fi
      pkgs["$pkg"]=1
    done < <(readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]$/\1/p')
  done < <(find "$dir" -type f \( -name '*.so*' -o -perm -u+x \) ! -name '*.o' ! -name '*.lo' -print0)
  printf '%s\n' "${!pkgs[@]}" | sort
}

# Step 4: the marker package, built in WORK, where apt's _apt user can read it.
build_marker() {
  local dir="$1" libs pyver pynext
  log "5. Building the marker package ${MARKER}..."
  libs="$(lib_packages "$dir")" || exit 1
  pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  pynext="${pyver%.*}.$(( ${pyver#*.} + 1 ))"
  mkdir -p "$WORK/marker/DEBIAN"
  cat > "$WORK/marker/DEBIAN/control" <<EOF
Package: ${MARKER}
Version: ${VERSION}+local1
Architecture: all
Maintainer: Local admin <root@localhost>
Section: misc
Priority: optional
Depends: python3 (>= ${pyver}~), python3 (<< ${pynext}), ${MARKER_DEPENDS}, $(paste -sd, <<<"$libs" | sed 's/,/, /g')
Recommends: ${MARKER_RECOMMENDS}
Conflicts: $(printf '%s, ' "${UBUNTU_PKGS[@]}" | sed 's/, $//')
Description: marker for HPLIP ${VERSION} built from HP's source
 HPLIP ${VERSION} was compiled from HP's signed hplip-${VERSION}.run and
 installed with 'make install', so dpkg doesn't track its files. This empty
 package keeps the libraries and Python modules they need from being
 autoremoved, and conflicts with Ubuntu's HPLIP packages, which would
 overwrite them. Managed by ~/scripts/hplip-from-hp.sh.
EOF
  MARKER_DEB="$WORK/${MARKER}_${VERSION}+local1_all.deb"
  if ! dpkg-deb --root-owner-group --build "$WORK/marker" "$MARKER_DEB" >/dev/null; then
    err "dpkg-deb couldn't build the marker package."
    exit 1
  fi
  chmod 755 "$WORK"
  [[ "$dir" == "$BUILD_DIR" ]] && cp "$MARKER_DEB" "$BUILD_DIR/"
  ok "${MARKER} ${VERSION}+local1; libraries it keeps: $(paste -sd' ' <<<"$libs")"
}

# --- steps 5-9: ask, back up, install (sudo) --------------------------------

# show_plan STEP SIMULATION QUESTION: what apt is about to do, then ask.
show_plan() {
  local plan="$2"
  if grep -q '^E:' <<<"$plan"; then
    err "apt can't do it:"
    grep '^E:' <<<"$plan" | show
    exit 1
  fi
  log "$1. What apt will do:"
  if grep -qE '^(Remv|Inst) ' <<<"$plan"; then
    grep -E '^(Remv|Inst) ' <<<"$plan" | sed -E 's/^Remv /remove  /; s/^Inst /install /' | show
  else
    echo "    nothing"
  fi
  if ! confirm "$3"; then
    log "Stopped. Nothing on the system has changed."
    exit 0
  fi
}

manifest() {
  local owner
  owner="$(code_owner)"
  [[ -n "$owner" ]] || owner="HP's source build (not tracked by dpkg)"
  echo "# hplip-from-hp.sh --$ACTION, $(date '+%F %T')"
  echo "# ${HPLIP_CONF} version: $(conf_version)"
  echo "# HPLIP's Python code from: $owner"
  # shellcheck disable=SC2016
  dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' "${UBUNTU_PKGS[@]}" "$MARKER" 2>/dev/null
}

# backup STEP: HPLIP's files and config plus CUPS's printer config, whoever
# installed them, so nothing this script replaces or removes is lost.
backup() {
  local p list=()
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  log "$1. Backing up to ${BACKUP_DIR}/..."
  shopt -s nullglob
  local candidates=(/etc/hp /etc/cups/printers.conf /etc/cups/ppd /etc/sane.d/dll.conf
    /etc/sane.d/dll.d/hplip /etc/udev/rules.d/56-hpmud.rules
    /etc/xdg/autostart/hplip-systray.desktop "$PIN_FILE"
    /usr/share/hplip /usr/share/ppd/HP /usr/share/cups/drv/hp /usr/share/cups/mime/pstotiff.*
    /usr/share/applications/hplip.desktop /usr/share/applications/hp-uiscan.desktop
    /usr/share/ipp-usb/quirks/HPLIP.conf /usr/share/hal/fdi/preprobe/10osvendor/20-hplip-devices.fdi
    /usr/lib/cups/backend/hp /usr/lib/cups/backend/hpfax /usr/lib/cups/filter/hp*
    /usr/lib/libhp* /usr/lib/libImageProcessor* /usr/lib/sane/libsane-hpaio*
    /usr/lib/x86_64-linux-gnu/libhpmud* /usr/lib/x86_64-linux-gnu/sane/libsane-hpaio*
    /usr/lib/python3/dist-packages/{cupsext,hpmudext,scanext,pcardext}.*
    /usr/lib/systemd/system/hplip-printer@.service /usr/bin/hp-* "$HOME/.hplip")
  shopt -u nullglob
  for p in "${candidates[@]}"; do
    if [[ -e "$p" || -L "$p" ]]; then list+=("${p#/}"); fi
  done
  printf '%s\n' "${list[@]}" > "$WORK/backup-paths.txt"
  manifest > "$WORK/manifest.txt"
  run mkdir -p "$BACKUP_DIR"
  run tar -czf "$BACKUP_DIR/hplip.tar.gz" -C / -T "$WORK/backup-paths.txt"
  run install -m 0644 "$WORK/manifest.txt" "$WORK/backup-paths.txt" "$BACKUP_DIR/"
  if [[ $DRY_RUN -eq 0 ]]; then
    ok "$(du -h "$BACKUP_DIR/hplip.tar.gz" | cut -f1) archive of ${#list[@]} paths, plus manifest.txt"
  fi
}

install_marker() {
  log "8. Installing ${MARKER}, which removes Ubuntu's HPLIP packages..."
  if ! run apt-get install -y "$MARKER_DEB"; then
    err "apt failed (see above). Nothing else has changed; the backup is in ${BACKUP_DIR}/."
    exit 1
  fi
}

write_pin() {
  log "9. Pinning Ubuntu's HPLIP packages to -1 (${PIN_FILE})..."
  {
    echo "# HPLIP is built from HP's source by ~/scripts/hplip-from-hp.sh. Ubuntu's HPLIP"
    echo "# packages write to the same paths and would replace it, as the 26.04 upgrade"
    echo "# did to 3.25.2, so none of them may be installed from any source, Ubuntu Pro"
    echo "# ESM included. To lift this: ~/scripts/hplip-from-hp.sh --undo"
    echo "Package: ${UBUNTU_PKGS[*]}"
    echo "Pin: version *"
    echo "Pin-Priority: -1"
  } > "$WORK/hplip-from-hp.pref"
  [[ $DRY_RUN -eq 1 ]] && show < "$WORK/hplip-from-hp.pref"
  run install -m 0644 "$WORK/hplip-from-hp.pref" "$PIN_FILE"
}

# systray_autostarts: your session starts the tray icon at login.
systray_autostarts() {
  local own="$HOME/.config/autostart/hplip-systray.desktop"
  [[ -f /etc/xdg/autostart/hplip-systray.desktop ]] || return 1
  if [[ -f "$own" ]] && grep -qiE '^(Hidden=true|X-GNOME-Autostart-enabled=false)' "$own"; then
    return 1
  fi
  return 0
}

# The tray icon (hp-systray) runs as you and keeps the old code loaded. Its
# replacement runs as a transient user service, so closing this terminal
# doesn't take it down; at the next login the autostart entry takes over.
# It's also started when it isn't running but your login would start it.
# The pattern is anchored: unanchored, it also matches any shell whose command
# line merely mentions the tray's path, and pkill would kill that shell.
TRAY_PATTERN='^/usr/bin/python3 /usr/bin/hp-systray'

restart_systray() {
  if pgrep -u "$USER" -f "$TRAY_PATTERN" >/dev/null; then
    run_user pkill -u "$USER" -f "$TRAY_PATTERN"
    [[ $DRY_RUN -eq 1 ]] || sleep 2
  elif ! systray_autostarts; then
    return 0
  fi
  run_user systemd-run --user --quiet --collect --unit="hp-systray-$(date +%s)" /usr/bin/hp-systray -x
  [[ $DRY_RUN -eq 1 ]] && return 0
  sleep 4
  if pgrep -u "$USER" -f "$TRAY_PATTERN" >/dev/null; then
    ok "Restarted the HP tray icon"
  else
    warn "The HP tray icon didn't come back; it starts again at your next login."
  fi
}

reload_services() {
  run ldconfig
  run systemctl daemon-reload
  run udevadm control --reload-rules
  run systemctl restart cups
  restart_systray
}

install_hplip() {
  log "10. Installing HPLIP ${VERSION}'s files (make install)..."
  if [[ -n "$PREV_BUILD" ]]; then
    log "   First removing HPLIP ${PREV_VERSION}, which this script installed (make uninstall)..."
    run_logged "$PREV_BUILD/uninstall.log" make -C "$PREV_BUILD" uninstall || exit 1
  fi
  if ! run_logged "$BUILD_DIR/install.log" make -C "$BUILD_DIR" install; then
    err "Ubuntu's HPLIP packages are already gone at this point. To get them back:"
    err "  ~/scripts/hplip-from-hp.sh --undo"
    exit 1
  fi
  reload_services
}

# --- step 10 / --status / --undo -----------------------------------------------

# check_queues: each CUPS queue on HPLIP's hp: or hpfax: backend is enabled,
# and each hp: one reports its supplies (the same query as Device Manager's
# Supplies tab for that entry).
check_queues() {
  local rc=0 q uri state st out levels
  while read -r q uri; do
    state="$(LC_ALL=C lpstat -p "$q" 2>/dev/null | head -n 1)"
    if [[ "$state" == *disabled* ]]; then
      err "$q is disabled: $state"
      rc=1
    else
      ok "$q (${uri%%\?*}) is enabled"
    fi
    [[ "$uri" == hp:* ]] || continue
    st="$(installed_status_type "$uri")"
    if [[ "$st" =~ ^[1-9][0-9]*$ ]]; then
      ok "HPLIP knows the model of $q, so Device Manager lists it"
    else
      err "HPLIP's models.dat doesn't know $q, so Device Manager finds no device"
      rc=1
    fi
    out="$(timeout 60 hp-levels -d "$uri" </dev/null 2>&1)"
    levels="$(supply_summary <<<"$out")"
    if [[ -n "$levels" ]]; then
      ok "$q supplies: $levels"
    else
      warn "Couldn't read the supply levels of $q:"
      grep -m 2 -iE 'error|no such|not found|traceback' <<<"$out" | sed 's/\x1b\[[0-9;]*m//g' | show
    fi
  done < <(hp_queues)
  return $rc
}

check_apply() {
  local rc=0 v owner live pkgs deps sim bad first
  log "11. Checking..."
  v="$(conf_version)"
  if [[ "$v" == "$VERSION" ]]; then ok "HPLIP reports version $v"
  else err "${HPLIP_CONF} says ${v:-nothing}, expected $VERSION"; rc=1; fi
  owner="$(code_owner)"
  if [[ -z "$owner" ]]; then ok "HPLIP's code is HP's build (dpkg doesn't track it)"
  else err "HPLIP's code belongs to the package $owner"; rc=1; fi
  if fax_fix_present; then ok "Device Manager has the fix for the fax Supplies crash"
  else err "Device Manager still lacks the fix for the fax Supplies crash"; rc=1; fi
  if modules_load; then ok "Its Python modules load (cupsext, hpmudext, scanext)"
  else err "Its Python modules don't load"; rc=1; fi
  if tools_start; then ok "Its tools start (hp-levels -h)"
  else err "Its tools don't start: see what 'hp-levels -h' prints"; rc=1; fi
  # The fax backend is root-only (mode 700), hence sudo for its first line.
  bad="$(bare_python_scripts /usr/share/hplip /usr/lib/cups/filter/pstotiff)"
  first="$(sudo head -n 1 /usr/lib/cups/backend/hpfax 2>/dev/null)"
  if [[ "$first" =~ $BARE_PYTHON_RE ]]; then bad+="${bad:+$'\n'}/usr/lib/cups/backend/hpfax"; fi
  if [[ -z "$bad" ]]; then ok "HPLIP's scripts run python3, the fax backend and filter included"
  else err "These still start with a bare 'python', which 26.04 doesn't have:"; show <<<"$bad"; rc=1; fi
  live="$(hplip_libhpmud)"
  if [[ -n "$live" ]] && ! dpkg -S "$live" >/dev/null 2>&1; then ok "HPLIP loads HP's libhpmud ($live)"
  else err "HPLIP loads ${live:-no} libhpmud.so.0, not HP's"; rc=1; fi
  pkgs="$(installed_ubuntu_pkgs | paste -sd' ')"
  if [[ -z "$pkgs" ]]; then ok "No Ubuntu HPLIP package is installed"
  else err "Still installed: $pkgs"; rc=1; fi
  if pin_active; then ok "apt has no candidate left for Ubuntu's HPLIP packages"
  else err "apt can still install Ubuntu's HPLIP packages"; rc=1; fi

  # What update.sh would do next: it runs dist-upgrade -y and autoremove -y.
  # shellcheck disable=SC2016
  deps="$(dpkg-query -W -f='${Depends}' "$MARKER" 2>/dev/null | tr ',|' '\n' \
          | sed -E 's/\(.*//; s/[[:space:]]//g' | grep -v '^$' | paste -sd' ')"
  sim="$({ apt-get -s dist-upgrade; apt-get -s autoremove; } 2>/dev/null \
         | awk -v deps="$deps" -v ub="${UBUNTU_PKGS[*]}" -v marker="$MARKER" '
             BEGIN { n = split(deps, d, " "); for (i = 1; i <= n; i++) keep[d[i]] = 1
                     n = split(ub, u, " ");   for (i = 1; i <= n; i++) blocked[u[i]] = 1 }
             $1 == "Remv" && ($2 == marker || ($2 in keep)) { print "remove  " $2 }
             $1 == "Inst" && ($2 in blocked)                { print "install " $2 }')"
  if [[ -z "$sim" ]]; then ok "A simulated dist-upgrade and autoremove leave HPLIP and its libraries alone"
  else err "update.sh would change HPLIP:"; show <<<"$sim"; rc=1; fi

  check_queues || rc=1
  return $rc
}

do_status() {
  local v owner live lo bad pkgs newest nv b found=0
  log "Installed HPLIP"
  v="$(conf_version)"
  echo "    version ${v:-unknown} (${HPLIP_CONF})"
  owner="$(code_owner)"
  if [[ -n "$owner" ]]; then
    echo "    code from Ubuntu's $owner $(pkg_version "$owner")"
  elif [[ -f "$DEVICE_PY" ]]; then
    echo "    code built from HP's source (dpkg doesn't track it)"
  else
    warn "no HPLIP code in /usr/share/hplip"
  fi
  if [[ -f "$DEVICE_PY" ]]; then
    if fax_fix_present; then ok "Device Manager has the fix for the fax Supplies crash"
    else warn "Device Manager can crash on the Supplies tab of a fax entry (fixed in HPLIP 3.26.6)"; fi
  fi
  if modules_load; then ok "Python modules load (cupsext, hpmudext, scanext)"
  else warn "HPLIP's Python modules don't load"; fi
  if tools_start; then ok "HPLIP's tools start (hp-levels -h)"
  else warn "HPLIP's tools don't start, Device Manager included (see 'hp-levels -h')"; fi
  if [[ -d /usr/share/hplip ]]; then
    bad="$(bare_python_scripts /usr/share/hplip /usr/lib/cups/filter/pstotiff | wc -l)"
    if (( bad == 0 )); then ok "HPLIP's scripts run python3"
    else warn "$bad HPLIP scripts start with a bare 'python', which 26.04 doesn't have (Device Manager won't start)"; fi
  fi
  live="$(hplip_libhpmud)"
  if [[ -n "$live" ]]; then
    lo="$(dpkg -S "$live" 2>/dev/null | head -n 1 | cut -d: -f1)"
    [[ -n "$lo" ]] || lo="HP's build"
    echo "    libhpmud in use: $live ($lo)"
  fi

  log "Packages"
  pkgs="$(installed_ubuntu_pkgs | paste -sd' ')"
  echo "    Ubuntu HPLIP packages installed: ${pkgs:-none}"
  if pkg_installed "$MARKER"; then echo "    ${MARKER} $(pkg_version "$MARKER") is installed"
  else echo "    ${MARKER} is not installed"; fi
  if [[ -f "$PIN_FILE" ]] && pin_active; then ok "pinned: apt can't install Ubuntu's HPLIP packages (${PIN_FILE})"
  elif [[ -f "$PIN_FILE" ]]; then warn "${PIN_FILE} exists, but apt still offers hplip-data"
  else echo "    no pin: updates can install Ubuntu's HPLIP packages"; fi

  log "Installers and build folders"
  newest="$(newest_run)"
  if [[ -n "$newest" ]]; then
    nv="$(run_version "$newest")"
    echo "    newest installer: ${newest/#"$HOME"/\~} (HPLIP ${nv:-?})"
    if [[ -n "$nv" && "$nv" != "$v" ]]; then
      echo "    to install it: ~/scripts/hplip-from-hp.sh"
    fi
  else
    echo "    no hplip-<version>.run in ~/Downloads"
  fi
  for b in "$BUILD_ROOT"/hplip-*/; do
    if [[ -f "$b$STAMP" ]]; then echo "    build folder: ${b%/}"; found=1; fi
  done
  (( found )) || echo "    no build folder made by this script"
  if pkg_installed "$MARKER" && [[ ! -f "$BUILD_ROOT/hplip-$v/Makefile" ]]; then
    warn "no build folder for the installed $v: --undo will re-create it from hplip-$v.run"
  fi

  log "Backups in ${BACKUP_ROOT}/"
  if compgen -G "$BACKUP_ROOT/*/manifest.txt" >/dev/null; then
    for b in "$BACKUP_ROOT"/*/; do echo "    ${b%/} ($(head -n 1 "$b/manifest.txt" | sed 's/^# //'))"; done
  else
    echo "    none"
  fi
}

do_undo() {
  local v f plan owner
  v="$(conf_version)"
  if ! pkg_installed "$MARKER" && [[ ! -f "$PIN_FILE" ]]; then
    ok "Nothing to undo: ${MARKER} isn't installed and there's no ${PIN_FILE}."
    return 0
  fi

  log "1. Checking the build folder of the installed HPLIP ${v}..."
  BUILD_DIR="$BUILD_ROOT/hplip-$v"
  if [[ -f "$BUILD_DIR/Makefile" && -f "$BUILD_DIR/$STAMP" ]]; then
    ok "$BUILD_DIR is ready for make uninstall"
  else
    warn "$BUILD_DIR is missing; re-creating it from hplip-${v}.run (configure only)"
    [[ -n "$RUN" ]] || RUN="$HOME/Downloads/hplip-$v.run"
    find_run
    if [[ "$VERSION" != "$v" ]]; then
      err "$RUN is HPLIP $VERSION, but $v is installed."
      exit 1
    fi
    verify_signature
    if [[ $DRY_RUN -eq 1 ]]; then
      SRC_DIR="$WORK/hplip-$v"
    else
      prepare_build_dir
      SRC_DIR="$BUILD_DIR"
    fi
    unpack_source "$SRC_DIR"
    configure_source "$SRC_DIR"
    ok "Configured"
  fi

  # The plan as apt will see it once the pin is gone.
  mkdir -p "$WORK/preferences.d"
  for f in /etc/apt/preferences.d/*; do
    [[ "$f" == "$PIN_FILE" ]] || cp "$f" "$WORK/preferences.d/" 2>/dev/null
  done
  plan="$(apt-get -s -o Dir::Etc::PreferencesParts="$WORK/preferences.d" install hplip hplip-gui 2>&1)"
  show_plan 2 "$plan" "Back up, remove HPLIP $v and put Ubuntu's HPLIP back?"

  backup 3
  log "4. Removing HPLIP ${v}'s files (make uninstall)..."
  run_logged "$BUILD_DIR/uninstall.log" make -C "$BUILD_DIR" uninstall || exit 1
  for f in "${HOOK_FILES[@]}"; do
    if [[ -e "$f" || -L "$f" ]]; then
      run mkdir -p "$BACKUP_DIR/removed$(dirname "$f")"
      run mv "$f" "$BACKUP_DIR/removed$f"
    fi
  done
  log "5. Removing the pin (moved into the backup)..."
  if [[ -f "$PIN_FILE" ]]; then
    run mkdir -p "$BACKUP_DIR/removed$(dirname "$PIN_FILE")"
    run mv "$PIN_FILE" "$BACKUP_DIR/removed$PIN_FILE"
  fi
  # --force-confmiss brings back /etc/hp/hplip.conf, which make uninstall
  # deleted and dpkg would otherwise treat as removed on purpose.
  log "6. Installing Ubuntu's hplip and hplip-gui (this removes ${MARKER})..."
  if ! run apt-get install -y -o Dpkg::Options::=--force-confmiss -o Dpkg::Options::=--force-confnew hplip hplip-gui; then
    err "apt failed (see above). HPLIP $v is already uninstalled; fix apt's problem and run:"
    err "  sudo apt-get install hplip hplip-gui"
    exit 1
  fi
  reload_services
  [[ $DRY_RUN -eq 1 ]] && return 0

  log "7. Checking..."
  owner="$(code_owner)"
  if [[ -n "$owner" ]]; then ok "HPLIP's code comes from Ubuntu's $owner $(pkg_version "$owner")"
  else err "HPLIP's code isn't from an Ubuntu package"; fi
  if pkg_installed "$MARKER"; then err "${MARKER} is still installed"; else ok "${MARKER} is gone"; fi
  if modules_load; then ok "Python modules load"; else err "HPLIP's Python modules don't load"; fi
  if tools_start; then ok "HPLIP's tools start (hp-levels -h)"; else err "HPLIP's tools don't start: see what 'hp-levels -h' prints"; fi
  check_queues || true
}

# --- main -------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
  err "Run this as yourself, not as root: it builds HPLIP as you and calls sudo for the rest."
  exit 1
fi

if [[ "$ACTION" == status ]]; then
  do_status
  exit 0
fi

need apt-get dpkg-query tar make curl gpg od
[[ "$ACTION" == apply ]] && need gcc g++ python3 python3-config dpkg-deb readelf ldconfig
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/hplip-from-hp.XXXXXX")"; then
  err "Could not create a temporary directory."
  exit 1
fi

# --apply and --undo change the system: a real run is logged, and it asks for
# sudo before the build rather than after it.
if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY RUN: the checks, the build and apt's plan run for real; nothing on the system changes."
else
  c_red=""; c_grn=""; c_ylw=""; c_blu=""; c_rst=""
  LOG_FILE="${SCRIPT_DIR}/hplip-from-hp-$(date +%Y%m%d-%H%M%S).log"
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
  [[ $DRY_RUN -eq 1 ]] && { echo; log "Dry run complete. Re-run without --dry-run to undo."; exit 0; }
  echo
  log "Done: Ubuntu's HPLIP is back, and updates manage it again."
  log "Full log of this run: ${LOG_FILE}"
  exit 0
fi

find_run
log "HPLIP ${VERSION} from ${RUN/#"$HOME"/\~}"
if pkg_installed "$MARKER"; then
  PREV_VERSION="$(conf_version)"
  if [[ "$PREV_VERSION" == "$VERSION" ]] && fax_fix_present && modules_load && tools_start && pin_active \
     && [[ -z "$(installed_ubuntu_pkgs)" ]] \
     && [[ -z "$(bare_python_scripts /usr/share/hplip /usr/lib/cups/filter/pstotiff)" ]]; then
    ok "HPLIP $VERSION from HP's source is already installed and in order; nothing to build."
    [[ $DRY_RUN -eq 1 ]] && exit 0
    check_apply
    exit $?
  fi
  if [[ -n "$PREV_VERSION" && "$PREV_VERSION" != "$VERSION" \
        && -f "$BUILD_ROOT/hplip-$PREV_VERSION/$STAMP" ]]; then
    PREV_BUILD="$BUILD_ROOT/hplip-$PREV_VERSION"
  fi
fi

verify_signature
if [[ $DRY_RUN -eq 1 ]]; then
  SRC_DIR="$WORK/hplip-$VERSION"
else
  prepare_build_dir
  SRC_DIR="$BUILD_DIR"
fi
unpack_source "$SRC_DIR"
apply_ubuntu_patches "$SRC_DIR"
fix_shebangs "$SRC_DIR"
build_source "$SRC_DIR"
smoke_test "$SRC_DIR"
build_marker "$SRC_DIR"

show_plan 6 "$(apt-get -s install "$MARKER_DEB" 2>&1)" \
  "Back up, then install HPLIP ${VERSION} from HP's source?"
backup 7
install_marker
write_pin
install_hplip

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  log "Dry run complete. Re-run without --dry-run to install."
  exit 0
fi

echo
if ! check_apply; then
  err "HPLIP $VERSION is installed, but the check found problems (above)."
  err "Full log: ${LOG_FILE}. To go back to Ubuntu's HPLIP: ~/scripts/hplip-from-hp.sh --undo"
  exit 1
fi
echo
log "Done: HPLIP ${VERSION} from HP's source, and Ubuntu's packages can't come back over it."
log "Full log of this run: ${LOG_FILE}"
log "Check anytime:  ~/scripts/hplip-from-hp.sh --status"
log "Revert:         ~/scripts/hplip-from-hp.sh --undo"
