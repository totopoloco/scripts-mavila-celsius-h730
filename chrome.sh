#!/usr/bin/env bash

MY_FACTOR=1.4
echo "Starting Google Chrome with a factor of: $MY_FACTOR"

google-chrome --disable-renderer-backgrounding --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
