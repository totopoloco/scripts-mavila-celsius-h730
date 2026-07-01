#!/bin/bash

# Get a list of all block devices
DEVICES=$(lsblk -dn -o NAME)

# Loop through each device and print out its usage
for DEVICE in $DEVICES; do
  echo "Usage for $DEVICE:"
  df -h /dev/$DEVICE
  echo "-------------------"
done

# Output:
# Usage for sda1:
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/sda1       916G  7.8G  862G   1% /
# -------------------

