#!/usr/bin/env bash
# disk_info.sh - used/free space per mounted volume, with a usage bar.
# Real filesystems only (ext4/xfs/btrfs/vfat/exfat/ntfs/f2fs/zfs) -- skips
# tmpfs, overlay, squashfs (snap loop mounts), proc, and other pseudo mounts.

set -uo pipefail

BAR_WIDTH=30
FS_TYPES=(ext2 ext3 ext4 xfs btrfs vfat exfat ntfs ntfs3 f2fs zfs)

if [ -t 1 ]; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BOLD=$(tput bold); RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# draw_bar <use%> -> "[####----]" colored green/yellow/red at 70%/90%.
draw_bar() {
  local pct="${1%\%}" width="$BAR_WIDTH" filled empty color
  case "$pct" in ''|*[!0-9]*) pct=0 ;; esac
  filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  empty=$(( width - filled ))
  if   [ "$pct" -ge 90 ]; then color=$RED
  elif [ "$pct" -ge 70 ]; then color=$YELLOW
  else                          color=$GREEN
  fi
  printf '[%s' "$color"
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%s' "$RESET"
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf ']'
}

type_args=()
for t in "${FS_TYPES[@]}"; do type_args+=(-t "$t"); done

printf "${BOLD}%-24s %-7s %7s %7s %7s  %-$((BAR_WIDTH + 2))s %s${RESET}\n" \
  "MOUNT" "FS" "SIZE" "USED" "AVAIL" "USAGE" "USE%"

df -h "${type_args[@]}" --output=target,fstype,size,used,avail,pcent 2>/dev/null | tail -n +2 |
  while read -r mount fstype size used avail pcent; do
    printf '%-24s %-7s %7s %7s %7s  %s %4s\n' \
      "$mount" "$fstype" "$size" "$used" "$avail" "$(draw_bar "$pcent")" "$pcent"
  done

echo
echo "  ${GREEN}##${RESET} <70% used   ${YELLOW}##${RESET} 70-89%   ${RED}##${RESET} >=90%"
