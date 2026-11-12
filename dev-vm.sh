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
FOUND=0
for INSTANCE in $INSTANCE_LIST; do
  if [ $INSTANCE = $VM_ID ]; then
    FOUND=1
  fi
done

if [ $FOUND = 1 ]; then
  echo "Using pre-existing ${VM_ID}"
else
  echo "Creating new ${VM_ID}, copied from ${BASE_VM}"
  incus copy $BASE_VM $VM_ID
fi

incus config device add $VM_ID share disk source=$(pwd) path=/mnt/ 2> /dev/null
incus config device set $VM_ID share source=$(pwd)
STATUS=$(incus info $VM_ID | grep 'Status: ')
if [ "$STATUS" = 'Status: STOPPED' ]; then
  incus start $VM_ID
  echo "Starting VM. Logging in when it's up"
else
  echo "VM already running. Logging in"
fi

until incus exec $VM_ID -- true 2>/dev/null; do sleep 1; done
incus exec $VM_ID -- bash -lc 'nixos-rebuild switch'
incus exec $VM_ID -- bash

COUNT_OP=$(incus operation list --format json | grep -o $VM_ID | wc -l)
if [ $COUNT_OP = 1 ]; then
  echo "shutting down ${VM_ID}"
  incus stop $VM_ID
else
  echo "other operations are still running on ${VM_ID}; didn't shut it down automatically."
fi

