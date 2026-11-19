# /etc/nixos/configuration.nix  —  NixOS-WSL base
#
# Files (all in /etc/nixos/):
#   configuration.nix        this file: base + imports
#   windows-isolation.nix    interop off, drives root-only under /win, network rules
#   users.nix                non-root user "agent", root only via `wsl -u root`
#   gpu-llama.nix            Windows GPU driver passthrough + llama.cpp (CUDA),
#                            llama-server user service + `oc` command
#   opencode.nix             OpenCode, connected to the local llama-server
#   tools.nix                git, vim
#
# FIRST-TIME SETUP ON A FRESH NixOS-WSL (default user is still "nixos" with sudo)
#   1. Copy the files to /etc/nixos/
#      (keep system.stateVersion at the value your fresh install had).
#      Add the unstable channel (used for OpenCode, see opencode.nix):
#        sudo nix-channel --add https://channels.nixos.org/nixos-unstable nixos-unstable
#        sudo nix-channel --update
#   2. Build once with the CUDA cache passed on the command line:
#        sudo nixos-rebuild boot \
#          --option extra-substituters https://cache.nixos-cuda.org \
#          --option extra-trusted-public-keys cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=
#      ("boot", not "switch": the user changes and sudo disappears.)
#   3. From Windows:  wsl --shutdown
#   4. From Windows:  wsl -d <Distro> -u root exit   (activates the new generation)
#   5. From Windows:  wsl --shutdown
#   From now on:  wsl -d <Distro>            -> user "agent" (no root rights)
#                 wsl -d <Distro> -u root    -> root (admin work, nixos-rebuild)
#
# NOTES
#   - Restart with `wsl --shutdown`, not `wsl -t <Distro>`: the latter can leave
#     stale cgroups behind and break the systemd user session.
#   - Windows side, in %UserProfile%\.wslconfig (applies to all distros):
#       [wsl2]
#       guiApplications=false   # disables WSLg: no GUI/clipboard access, frees ~1 GB VRAM

{ config, lib, pkgs, ... }:

{
  imports = [
    <nixos-wsl/modules>
    ./windows-isolation.nix
    ./users.nix
    #./gpu-llama.nix
    #./opencode.nix
    #./tools.nix
  ];

  wsl.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.05"; # Did you read the comment?
}
