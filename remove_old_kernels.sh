#!/usr/bin/env bash
#
# remove_old_kernels.sh
#
# Purges old kernels. With no arguments it only shows what it would do.
#
# It keeps:
#   * the running kernel;
#   * the newest installed kernel of each flavour (generic, gke, ...), so a kernel
#     that is installed but not booted yet survives, and so does a fallback;
#   * anything not older than that newest kernel (a headers metapackage can move
#     ahead of the image), and any kernel with a held package;
#   * metapackages such as linux-generic or linux-headers-gke, and everything else
#     with no kernel version in its name. Without those, kernels stop updating.
#
# It purges every other package with a kernel version in its name (image, modules,
# headers, tools, ...), plus what removed kernels left behind in dpkg's "rc" state.
#
# apt simulates the purge first. If it would also remove or install anything else,
# the script stops without changing anything. It never runs autoremove.
#
# A real run is recorded to a timestamped log next to this script
# (remove_old_kernels-YYYYmmdd-HHMMSS.log).
#
# Usage:
#   ./remove_old_kernels.sh                     # preview, changes nothing, no root
#   ./remove_old_kernels.sh --dry-run           # same (also -n)
#   sudo ~/scripts/remove_old_kernels.sh exec   # purge; apt asks before it starts
#
set -uo pipefail

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_rst=$'\e[0m'

log()  { echo "${c_blu}==>${c_rst} $*"; }
ok()   { echo "${c_grn}  ok${c_rst} $*"; }
warn() { echo "${c_ylw}  ! ${c_rst} $*"; }
err()  { echo "${c_red}  x ${c_rst} $*" >&2; }

EXEC=0
if [[ $# -gt 1 ]]; then
  err "Expected one argument at most (try --help)"
  exit 2
fi
case "${1:-}" in
  ""|-n|--dry-run) ;;
  exec) EXEC=1 ;;
  -h|--help)
    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0"
    exit 0
    ;;
  *)
    err "Unknown option: $1 (try --help)"
    exit 2
    ;;
esac

if (( EXEC )); then
  if [[ $EUID -ne 0 ]]; then
    err "exec needs root: sudo ~/scripts/remove_old_kernels.sh exec"
    exit 1
  fi
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LOG_FILE="${SCRIPT_DIR}/remove_old_kernels-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee "$LOG_FILE") 2>&1
  LOG_TEE_PID=$!
  # bash does not wait for the tee process substitution; flush it on exit so the
  # log is complete (close our fds first so tee sees EOF, then reap it).
  trap 'exec >&- 2>&-; wait "$LOG_TEE_PID" 2>/dev/null' EXIT
  log "Logging this run to: $LOG_FILE"
fi

# True when version $1 sorts strictly before version $2.
older_than() { [[ $1 != "$2" ]] && printf '%s\n' "$1" "$2" | sort -VC; }

# linux-<anything>-<x.y.z>-<abi>[-<flavour>]. Group 1 is x.y.z-abi, group 2 -flavour.
VERSIONED='^linux-.+-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)(-[a-z0-9-]+)?$'

RUNNING=$(uname -r)
declare -A NEWEST=()      # flavour -> newest installed kernel release
declare -A KEEP_REL=()    # release (7.0.0-43-generic) -> 1
declare -A KEEP_BASE=()   # shared by a version's flavours (7.0.0-43) -> 1
declare -a INSTALLED=() CONFIG_ONLY=() OLD=() LEFTOVERS=()

KEEP_REL[$RUNNING]=1
[[ linux-image-$RUNNING =~ $VERSIONED ]] && KEEP_BASE[${BASH_REMATCH[1]}]=1

while read -r status pkg; do
  [[ $pkg =~ $VERSIONED ]] || continue
  base=${BASH_REMATCH[1]}
  flavour=${BASH_REMATCH[2]#-}
  release=$base${flavour:+-$flavour}
  case $status in
    ?n*) continue ;;
    ?c*) CONFIG_ONLY+=("$pkg"); continue ;;
    h*)  KEEP_REL[$release]=1; KEEP_BASE[$base]=1 ;;
  esac
  INSTALLED+=("$pkg")
  if [[ -n $flavour && $pkg =~ ^linux-image-(unsigned-)?$release$ ]]; then
    if [[ -z ${NEWEST[$flavour]:-} ]] || older_than "${NEWEST[$flavour]}" "$release"; then
      NEWEST[$flavour]=$release
    fi
  fi
done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*')

for release in "${NEWEST[@]}"; do
  KEEP_REL[$release]=1
  [[ linux-image-$release =~ $VERSIONED ]] && KEEP_BASE[${BASH_REMATCH[1]}]=1
done

# Flavoured packages go first: they decide which shared packages are still needed.
for pkg in "${INSTALLED[@]}"; do
  [[ $pkg =~ $VERSIONED ]] || continue
  base=${BASH_REMATCH[1]}
  flavour=${BASH_REMATCH[2]#-}
  [[ -n $flavour ]] || continue
  release=$base-$flavour
  if [[ -z ${KEEP_REL[$release]:-} && -n ${NEWEST[$flavour]:-} ]] \
      && older_than "$release" "${NEWEST[$flavour]}"; then
    OLD+=("$pkg")
  else
    KEEP_REL[$release]=1
    KEEP_BASE[$base]=1
  fi
done

# linux-headers-7.0.0-43, linux-gke-headers-7.0.0-1010, linux-tools-7.0.0-43, ...
for pkg in "${INSTALLED[@]}"; do
  [[ $pkg =~ $VERSIONED ]] || continue
  [[ -z ${BASH_REMATCH[2]} ]] || continue
  [[ -n ${KEEP_BASE[${BASH_REMATCH[1]}]:-} ]] || OLD+=("$pkg")
done

# A kept kernel's "rc" packages stay too: purging an "rc" linux-image package runs
# a postrm that deletes modules.dep and friends in /usr/lib/modules/<release>, even
# when another package still provides that kernel.
for pkg in "${CONFIG_ONLY[@]}"; do
  [[ $pkg =~ $VERSIONED ]] || continue
  base=${BASH_REMATCH[1]}
  flavour=${BASH_REMATCH[2]#-}
  if [[ -n $flavour ]]; then
    [[ -n ${KEEP_REL[$base-$flavour]:-} ]] || LEFTOVERS+=("$pkg")
  else
    [[ -n ${KEEP_BASE[$base]:-} ]] || LEFTOVERS+=("$pkg")
  fi
done

log "Running kernel: $RUNNING"
log "Keeping:"
newest_list=" ${NEWEST[*]} "
while read -r release; do
  why=""
  [[ $release == "$RUNNING" ]] && why="running"
  [[ $newest_list == *" $release "* ]] && why="${why:+$why, }newest of its flavour"
  echo "    $release (${why:-held, or not older than the newest of its flavour})"
done < <(printf '%s\n' "${!KEEP_REL[@]}" | sort -V)

TARGETS=("${OLD[@]}" "${LEFTOVERS[@]}")
if (( ${#TARGETS[@]} == 0 )); then
  ok "Nothing to purge."
  exit 0
fi

if (( ${#OLD[@]} )); then
  log "To purge, packages of old kernels (${#OLD[@]}):"
  printf '%s\n' "${OLD[@]}" | sort -V | sed 's/^/    /'
fi
if (( ${#LEFTOVERS[@]} )); then
  log "To purge, config left behind by kernels already removed (${#LEFTOVERS[@]}):"
  printf '%s\n' "${LEFTOVERS[@]}" | sort -V | sed 's/^/    /'
fi

log "Simulating the purge with apt..."
if ! plan=$(LC_ALL=C apt-get -s purge "${TARGETS[@]}" 2>&1); then
  err "apt can't plan this purge, so nothing was changed:"
  printf '%s\n' "$plan" >&2
  exit 1
fi

declare -A IS_TARGET=()
for pkg in "${TARGETS[@]}"; do IS_TARGET[$pkg]=1; done
EXTRAS=()
while read -r action pkg _; do
  case $action in
    Purg|Remv) [[ -n ${IS_TARGET[${pkg%%:*}]:-} ]] || EXTRAS+=("remove  $pkg") ;;
    Inst)      EXTRAS+=("install $pkg") ;;
  esac
done <<< "$plan"

if (( ${#EXTRAS[@]} )); then
  err "apt would also change packages outside this list, so nothing was changed:"
  printf '    %s\n' "${EXTRAS[@]}" >&2
  exit 1
fi
ok "apt would change only the packages listed above."

if (( ! EXEC )); then
  log "Preview only, nothing was changed. To purge: sudo ~/scripts/remove_old_kernels.sh exec"
  exit 0
fi

log "Purging ${#TARGETS[@]} package(s)..."
apt-get purge "${TARGETS[@]}"
rc=$?
if (( rc != 0 )); then
  err "apt-get purge exited with status $rc."
  exit "$rc"
fi
ok "Done."
