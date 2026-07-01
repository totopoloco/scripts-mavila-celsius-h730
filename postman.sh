#!/usr/bin/env bash

MY_FACTOR=1.2
echo "Starting Postman with a factor of: $MY_FACTOR"

postman --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
