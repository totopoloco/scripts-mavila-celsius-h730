#!/usr/bin/env bash

MY_FACTOR=1.4
echo "Starting Sublime with a factor of: $MY_FACTOR"

sublime-text.subl --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
