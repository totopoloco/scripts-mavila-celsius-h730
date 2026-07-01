#!/usr/bin/env bash

MY_FACTOR=1.3
echo "Starting MS Teams with a factor of: $MY_FACTOR"

/usr/share/teams/teams --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
echo $?
