#!/bin/bash

source .env
BASE_VM="nixos"

incus stop "$BASE_VM" 2> /dev/null
incus delete "$BASE_VM" 2> /dev/null

incus init images:nixos/26.05 "$BASE_VM" --vm \
  --config limits.cpu=4 \
  --config limits.memory=8GiB \
  --device root,size=100GiB \
  --config security.secureboot=false
incus config set "$BASE_VM" raw.idmap $'uid 1000 0\ngid 1000 0'

echo "Starting and configuring VM"
incus start "$BASE_VM"
until incus exec "$BASE_VM" -- bash -lc 'systemctl is-active --quiet dbus.service' 2>/dev/null; do sleep 1; done
incus exec "$BASE_VM" -- timedatectl set-timezone "$(timedatectl show -p Timezone --value)"
incus file push nix/* "$BASE_VM"/etc/nixos/
incus config set "$BASE_VM" environment.CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
incus exec "$BASE_VM" -- bash -lc 'nixos-rebuild switch'
incus stop "$BASE_VM"

