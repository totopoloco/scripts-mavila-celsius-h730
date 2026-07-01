#!/usr/bin/env bash

echo 'Starting MS Edge'

/opt/microsoft/msedge/msedge --force-device-scale-factor=1.2 > /dev/null 2>&1 &
