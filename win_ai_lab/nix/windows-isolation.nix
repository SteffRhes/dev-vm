# Isolation of the VM from Windows and the local network.
#
#   agent: no Windows drives, no Windows programs, no WSLg sockets (best effort),
#          no connections to the Windows host or the LAN (internet, DNS and
#          127.0.0.1 inside the VM still work)
#   root:  Windows drives under /win (c, d, ...), no Windows programs,
#          no SMB / NetBIOS / NFS
#
# After changes: `nixos-rebuild switch` as root, then `wsl --shutdown` from Windows.
#
# CHECKS
#   as agent:
#     ls /win                                   -> Permission denied
#     ls /mnt/c                                 -> No such file or directory
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
#     systemctl status nftables
#     nft list ruleset

{ config, lib, ... }:

let
  user = config.wsl.defaultUser;
  # Numeric uid: the ruleset is checked at build time, where user names don't exist.
  uid = config.users.users.${user}.uid;
in
{
  assertions = [{
    assertion = uid != null;
    message = "windows-isolation.nix: set users.users.${user}.uid explicitly (see `id -u ${user}`).";
  }];

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
  # Windows drives: root only, under /win
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

  # WSLg (Linux GUI apps on the Windows desktop, shared clipboard, audio):
  # WSLg lives under the automount root (/win/wslg), which only root can enter.
  # NixOS-WSL additionally bind-mounts the X11 socket to /tmp/.X11-unix/X0, where
  # agent could reach it (and with it the clipboard); this masks that mount.
  # The most reliable way is global, on the Windows side, in %UserProfile%\.wslconfig:
  #   [wsl2]
  #   guiApplications=false
  systemd.units."tmp-.X11\\x2dunix-X0.mount".enable = lib.mkForce false;

  # DNS: WSL links /etc/resolv.conf to <automount root>/wsl/resolv.conf, i.e.
  # /win/wsl/resolv.conf, which agent cannot read (no DNS for agent).
  # Copy it to /etc/resolv.conf as a normal, world-readable file at every start.
  # Keeps the DNS server WSL assigns (DNS tunneling, VPN, company DNS).
  # If Windows' network changes while the VM runs: systemctl restart wsl-resolv-conf
  systemd.services.wsl-resolv-conf = {
    description = "Copy WSL resolv.conf out of /win so all users can read it";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "network.target" "nss-lookup.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ -f /win/wsl/resolv.conf ]; then
        install -m 0644 /win/wsl/resolv.conf /etc/resolv.conf.new
        mv -f /etc/resolv.conf.new /etc/resolv.conf
      fi
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
