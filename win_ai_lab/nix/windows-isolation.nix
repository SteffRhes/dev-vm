# Separation of the VM from Windows and the local network, and of "agent" from root.
#
#   agent: regular user without any way to root (no sudo/doas/su, no wheel).
#          Windows access only to D: (/mnt/d) and %UserProfile%\aivm (/mnt/aivm),
#          read + write. No other Windows drives, no Windows programs, no WSLg
#          sockets (best effort), no connections to the Windows host or the LAN
#          (internet, DNS and 127.0.0.1 inside the VM still work).
#   root:  only via `wsl -u root`. All Windows drives under /win (c, d, ...),
#          no Windows programs, no SMB / NetBIOS / NFS.
#
# After changes: `nixos-rebuild switch` as root, then `wsl --shutdown` from Windows.
#
# Changing wsl.defaultUser on an existing system: apply with `nixos-rebuild boot`
# (not switch), then `wsl --shutdown`, `wsl -d <Distro> -u root exit`, `wsl --shutdown`.
# The previous user ("nixos") is removed from /etc/passwd; its home directory stays
# and can be deleted manually as root.
#
# The Windows path of the aivm folder is read from /etc/nixos/aivm-path (one line,
# e.g. C:\Users\<you>\aivm), which setup.ps1 writes. Without that file /mnt/aivm is
# not mounted and the rebuild prints a warning.
#
# CHECKS
#   as agent:
#     ls /win                                   -> Permission denied
#     ls /mnt/c                                 -> No such file or directory
#     touch /mnt/d/x /mnt/aivm/x && rm /mnt/d/x /mnt/aivm/x   -> works
#     sudo true; su                             -> not found / fails
#     cmd.exe                                   -> cannot execute / not found
#     ip route | awk '/default/ {print $3}'     -> Windows host (gateway) IP
#     curl -m 5 http://<gateway-ip>/            -> timeout
#     curl -m 5 http://192.168.1.1/             -> timeout (router)
#     curl -sI https://nixos.org | head -1      -> works (internet + DNS)
#     curl -s http://127.0.0.1:8080/health      -> works (llama-server, if running)
#     nix-shell -p wl-clipboard xclip --run 'wl-paste; xclip -o -selection clipboard'
#                                               -> should fail (no clipboard access)
#   as root:
#     ls /win/c /win/d
#     findmnt /mnt/d; findmnt /mnt/aivm
#     systemctl status nftables
#     nft list ruleset

{ config, lib, ... }:

let
  user = "agent";
  # Fixed uid: used by the firewall rules (checked at build time, where user names
  # don't exist) and the drive mounts. Must match the existing user: check with
  # `id -u agent` before changing.
  uid = 1000;
  gid = config.users.groups.users.gid;   # agent's primary group "users" (100)

  # Mount options for the folders agent may use: owned by agent, nobody else
  # (except root) has access. "metadata" is left out on purpose (see /win below),
  # so chmod/chown on these mounts have no effect.
  agentDrvfs = [ "uid=${toString uid}" "gid=${toString gid}" "umask=077" "nofail" ];

  aivmPathFile = ./aivm-path;
  aivmPath =
    if builtins.pathExists aivmPathFile
    then lib.strings.trim (builtins.readFile aivmPathFile)
    else null;
in
{
  ##########################################################################
  # Users: agent without root rights, root only via `wsl -u root`
  ##########################################################################
  wsl.defaultUser = user;

  users.users.${user} = {
    inherit uid;

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

  ##########################################################################
  # Windows interop: off for everyone
  ##########################################################################
  # With interop, any Windows program (cmd.exe, powershell.exe, wsl.exe, net use)
  # runs with the Windows user's rights, which would bypass the mount restrictions,
  # the network rules and the user separation (wsl.exe -u root).
  wsl.wslConf.interop.enabled = false;
  wsl.wslConf.interop.appendWindowsPath = false;
  wsl.interop.register = false;
  wsl.interop.includePath = false;
  wsl.startMenuLaunchers = false;

  ##########################################################################
  # Windows drives: all of them root only, under /win
  ##########################################################################
  # Two layers: /win itself is root-only (0700), and the drive files appear
  # root-owned with no permissions for others. "metadata" is left out on purpose:
  # with it, files created earlier from WSL keep their stored owner/permissions
  # (e.g. uid 1000) and would bypass the umask.
  #
  # Root can mount further paths manually; keep them under /win, e.g.:
  #   mount -t drvfs 'D:\LMStudio\models' /win/models -o ro,uid=0,gid=0,umask=077
  #
  # Do not let root copy files prepared by agent onto the Windows drives unchecked:
  # that would give agent a way to place files Windows later runs.
  wsl.wslConf.automount.enabled = true;
  wsl.wslConf.automount.root = "/win";
  wsl.wslConf.automount.options = "uid=0,gid=0,umask=077";
  wsl.wslConf.automount.mountFsTab = false;

  systemd.tmpfiles.rules = [
    # Only root may enter /win (reset at every boot, before agent can log in).
    "d /win 0700 root root -"

    # WSLg fallback: if WSLg is mounted at /mnt/wslg instead of /win/wslg,
    # keep agent out of it too. Ignored if /mnt/wslg does not exist.
    "z /mnt/wslg 0700 root root -"
  ];

  ##########################################################################
  # Windows folders for agent (read + write): /mnt/d and /mnt/aivm
  ##########################################################################
  # Separate drvfs mounts (not bind mounts of /win/...), since drvfs fixes the
  # owner per mount: here agent, under /win root. Mounted by systemd at boot;
  # "nofail" keeps the boot going if D: or the folder is missing.
  # Everything agent writes here is a real Windows file: Windows (and you) may
  # open or run it later, so treat it as untrusted.
  fileSystems = {
    "/mnt/d" = {
      device = "D:";
      fsType = "drvfs";
      options = agentDrvfs;
    };
  } // lib.optionalAttrs (aivmPath != null) {
    "/mnt/aivm" = {
      device = aivmPath;
      fsType = "drvfs";
      options = agentDrvfs;
    };
  };

  warnings = lib.optional (aivmPath == null)
    "windows-isolation.nix: /etc/nixos/aivm-path is missing, /mnt/aivm is not mounted (run setup.ps1 or create it with the Windows path, e.g. C:\\Users\\<you>\\aivm).";

  # WSLg (Linux GUI apps on the Windows desktop, shared clipboard, audio):
  # WSLg lives under the automount root (/win/wslg), which only root can enter.
  # NixOS-WSL additionally bind-mounts the X11 socket to /tmp/.X11-unix/X0, where
  # agent could reach it (and with it the clipboard); this masks that mount.
  # The most reliable way is global, on the Windows side, in %UserProfile%\.wslconfig:
  #   [wsl2]
  #   guiApplications=false
  systemd.units."tmp-.X11\\x2dunix-X0.mount".enable = lib.mkForce false;

  # DNS: by default WSL links /etc/resolv.conf to <automount root>/wsl/resolv.conf,
  # i.e. /win/wsl/resolv.conf, and re-creates that link at every session start.
  # Behind /win (0700) only root can read it, so DNS fails for agent and for nsncd
  # (the glibc name lookup daemon), i.e. effectively for everyone.
  # Instead, WSL stops generating it and /etc/resolv.conf is a fixed file pointing
  # to WSL's DNS tunneling resolver. 10.255.255.254 is fixed by WSL (DNS tunneling
  # is the default since WSL 2.2) and forwards to Windows' DNS, so VPN and company
  # DNS keep working. If dnsTunneling=false is set in .wslconfig, use the gateway
  # IP instead (`ip route | awk '/default/ {print $3}'`).
  wsl.wslConf.network.generateResolvConf = false;
  networking.resolvconf.enable = false;
  environment.etc."resolv.conf" = lib.mkForce {
    mode = "0644";   # a real file, replaces WSL's old symlink into /win
    text = ''
      nameserver 10.255.255.254
    '';
  };

  ##########################################################################
  # Network
  ##########################################################################
  # block-shares:     nobody may use SMB / NetBIOS / NFS.
  # agent-isolation:  agent may not reach the Windows host (WSL NAT gateway), private
  #                   IPv4 ranges, link-local, CGNAT/Tailscale (100.64.0.0/10),
  #                   multicast/broadcast (mDNS, SSDP), IPv6 ULA/link-local/multicast.
  #                   DNS (port 53) is allowed, since the resolver is the Windows host.
  # Not covered: LAN devices or the Windows host reached via public IPv6 addresses;
  # loopback in WSL "mirrored" networking mode (there 127.0.0.1 can reach Windows
  # services; the default NAT mode is not affected).
  networking.nftables.enable = true;

  # The WSL kernel lacks the nftables "fib" module used by the reverse-path check;
  # without this the whole ruleset fails to load.
  networking.firewall.checkReversePath = false;

  networking.nftables.tables.block-shares = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority 0; policy accept;
        tcp dport { 139, 445, 2049 } drop
        udp dport { 137, 138, 2049 } drop
      }
    '';
  };

  networking.nftables.tables.agent-isolation = {
    family = "inet";
    content = ''
      set private4 {
        type ipv4_addr; flags interval
        elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16,
                     100.64.0.0/10, 224.0.0.0/4, 255.255.255.255 }
      }
      set private6 {
        type ipv6_addr; flags interval
        elements = { fc00::/7, fe80::/10, ff00::/8 }
      }
      chain output {
        type filter hook output priority 0; policy accept;
        meta skuid != ${toString uid} accept   # everyone except ${user}

        # DNS goes through the Windows host / WSL resolver (a private address)
        ip  daddr @private4 meta l4proto { tcp, udp } th dport 53 accept
        ip6 daddr @private6 meta l4proto { tcp, udp } th dport 53 accept

        ip  daddr @private4 drop
        ip6 daddr @private6 drop
      }
    '';
  };
}
