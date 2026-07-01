#!/usr/bin/env bash

MY_FACTOR=1.2
echo "Starting Telegram with a factor of: $MY_FACTOR"

telegram-desktop --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
