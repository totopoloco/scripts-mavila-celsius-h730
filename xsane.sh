#!/usr/bin/env bash

MY_DEVICE="${1:-airscan:e1:HP Color LaserJet Pro MFP 3302 [DB9CFB]}"
echo "Starting XSane with device: $MY_DEVICE"

xsane "$MY_DEVICE" > /dev/null 2>&1 &
