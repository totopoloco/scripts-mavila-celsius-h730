#!/usr/bin/env bash

MY_FACTOR=1.2
echo "Starting MongoDB with a factor of: $MY_FACTOR"

mongodb-compass --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
