#!/usr/bin/env bash

MY_FACTOR=1.2
echo "Starting Visual Studio Code with a factor of: $MY_FACTOR"

code --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
