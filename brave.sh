#!/usr/bin/env bash

MY_FACTOR=1.3
echo "Starting Brave with a factor of: $MY_FACTOR"

brave-browser --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
