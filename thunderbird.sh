#!/usr/bin/env bash

MY_FACTOR=1.7
echo "Starting Thunderbird with a factor of: $MY_FACTOR"

thunderbird --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
