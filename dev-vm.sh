#!/bin/bash

BASE_VM="nixos"

if [[ -f .dev-vm ]]; then
  VM_ID=$(cat .dev-vm)
else
  VM_ID=$(cat /proc/sys/kernel/random/uuid)
  VM_ID="${BASE_VM}--${VM_ID}"
  echo $VM_ID > .dev-vm
fi

INSTANCE_LIST=$(incus list -c n -f csv)
for INSTANCE in $INSTANCE_LIST; do
  FOUND=0
  if [ $INSTANCE = $VM_ID ]; then
    FOUND=1
  fi
done

if [ $FOUND = 0 ]; then
  incus copy $BASE_VM $VM_ID
fi

incus config device add $VM_ID shared disk source=$(pwd) path=/mnt/ 2> /dev/null
incus config device set $VM_ID shared source=$(pwd)
STATUS=$(incus info $VM_ID | grep 'Status: ')
if [ "$STATUS" = 'Status: STOPPED' ]; then
  incus start $VM_ID
  echo "starting ${VM_ID}. Logging in, once it's up"
fi

while [[ -z $IS_UP ]]; do
  UP_YET=$(incus exec $VM_ID -- echo up 2> /dev/null)
  if [ "$UP_YET" = "up" ]; then
    IS_UP=1
  fi
  sleep 1
done
incus exec $VM_ID -- bash

