#!/bin/bash

BASE_VM="nixos"

incus stop "$BASE_VM" 2> /dev/null
incus delete "$BASE_VM" 2> /dev/null

incus init images:nixos/26.05 "$BASE_VM" --vm --config limits.cpu=8 --config limits.memory=8000MiB --config security.secureboot=false
incus config set "$BASE_VM" raw.idmap $'uid 1000 0\ngid 1000 0'

incus start "$BASE_VM"
until incus exec "$BASE_VM" -- true 2>/dev/null; do sleep 1; done
#incus file push nix/configuration_modified_basic.nix "$BASE_VM"/etc/nixos/configuration.nix
incus file push nix/configuration_modified_agentic.nix "$BASE_VM"/etc/nixos/configuration.nix
incus exec "$BASE_VM" -- bash -lc 'nixos-rebuild switch'
incus stop "$BASE_VM"

