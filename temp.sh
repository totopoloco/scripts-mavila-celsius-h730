#!/usr/bin/env bash
# temp.sh - quick CPU temperature report (use -w to watch).
# Reads lm-sensors if available, else /sys/class/thermal.

show() {
  if command -v sensors >/dev/null 2>&1; then
    sensors 2>/dev/null | grep -E 'Package id|Core [0-9]+:' \
      | sed -E 's/\s+\(.*$//'
  fi
  for z in /sys/class/thermal/thermal_zone*; do
    [ -e "$z/temp" ] || continue
    printf '%-14s %5.1f C\n' "$(cat "$z/type" 2>/dev/null)" \
      "$(awk '{print $1/1000}' "$z/temp")"
  done
  printf 'governor: %s\n' \
    "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
}

if [ "${1:-}" = "-w" ]; then
  while :; do clear; date '+%H:%M:%S'; show; sleep "${2:-2}"; done
else
  show
fi
