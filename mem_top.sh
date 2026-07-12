#!/usr/bin/env bash
# mem_top.sh - top memory-consuming processes, RSS shown in M/G (use -w to watch).
# Usage: mem_top.sh [N]        top N processes (default 10)
#        mem_top.sh -w [N]     watch, refreshing every 2s

set -uo pipefail

if [ -t 1 ]; then
  BOLD=$(tput bold); RESET=$(tput sgr0)
else
  BOLD=""; RESET=""
fi

show() {
  local n="${1:-10}"
  ps -eo pid,user,rss,%cpu,comm --sort=-rss | head -n "$((n + 1))" \
    | awk -v bold="$BOLD" -v reset="$RESET" '
        NR==1 {
          printf "%s%8s %-10s %8s %6s  %s%s\n", bold, "PID","USER","MEM","%CPU","COMMAND", reset
          next
        }
        {
          kb = $3
          mem = (kb >= 1048576) ? sprintf("%.1fG", kb/1048576) : sprintf("%.1fM", kb/1024)
          cmd = $5
          for (i=6; i<=NF; i++) cmd = cmd" "$i
          printf "%8s %-10s %8s %6s  %s\n", $1, $2, mem, $4"%", cmd
        }'
}

if [ "${1:-}" = "-w" ]; then
  n="${2:-10}"
  while :; do clear; date '+%H:%M:%S'; show "$n"; sleep 2; done
else
  show "${1:-10}"
fi
