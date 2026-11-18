# Regular user "agent" without any way to root; root only via `wsl -u root`.
#
# Changing wsl.defaultUser on an existing system: apply with `nixos-rebuild boot`
# (not switch), then `wsl --shutdown`, `wsl -d <Distro> -u root exit`, `wsl --shutdown`.
# The previous user ("nixos") is removed from /etc/passwd; its home directory stays
# and can be deleted manually as root.

{ config, lib, ... }:

{
  wsl.defaultUser = "agent";

  users.users.${config.wsl.defaultUser} = {
    # Fixed uid, used by the firewall rules in windows-isolation.nix.
    # Must match the existing user: check with `id -u agent` before changing.
    uid = 1000;

    # NixOS-WSL puts the default user into "wheel"; remove all extra groups.
    # Do not add root-equivalent groups here (wheel, docker, libvirtd, lxd).
    extraGroups = lib.mkForce [ ];
  };

  # No privilege escalation tools
  security.sudo.enable = false;
  security.sudo-rs.enable = false;
  security.doas.enable = false;
  security.pam.services.su.requireWheel = true;

  # Root has no usable password; WSL logs in as root without one (`wsl -u root`).
  users.users.root.hashedPassword = "!";

  # Trusted Nix users are effectively root.
  nix.settings.trusted-users = [ "root" ];
}
