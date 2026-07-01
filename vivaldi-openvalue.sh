#!/usr/bin/env bash
#
# Launch Vivaldi as the "openvalue" work user from the mavila session.
# Requires X11 (check: echo $XDG_SESSION_TYPE).

set -euo pipefail

WORK_USER="openvalue"
SCALE_FACTOR=1.1

if [[ "${XDG_SESSION_TYPE:-}" != "x11" ]]; then
    echo "Error: this script needs an X11 session (current: ${XDG_SESSION_TYPE:-unknown})." >&2
    exit 1
fi

if ! id "$WORK_USER" >/dev/null 2>&1; then
    echo "Error: user '$WORK_USER' does not exist." >&2
    exit 1
fi

xhost "+SI:localuser:$WORK_USER" >/dev/null

cleanup() {
    xhost "-SI:localuser:$WORK_USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sudo -u "$WORK_USER" -H \
    env DISPLAY="$DISPLAY" \
        XAUTHORITY="/home/$WORK_USER/.Xauthority-mavila" \
    bash -c "
        cp '$HOME/.Xauthority' '/home/$WORK_USER/.Xauthority-mavila' 2>/dev/null || true
        vivaldi --force-device-scale-factor=$SCALE_FACTOR > /dev/null 2>&1
    "
