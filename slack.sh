#!/usr/bin/env bash

MY_FACTOR=1.2
echo "Starting Slack with a factor of: $MY_FACTOR"

/usr/lib/slack/slack --force-device-scale-factor=$MY_FACTOR > /dev/null 2>&1 &
