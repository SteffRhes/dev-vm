{ modulesPath, config, lib, pkgs, ... }:

{
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-code" ];
  environment.systemPackages = [ pkgs.claude-code ];
  systemd.tmpfiles.settings."10-claude" = {
    "/root/.claude".d = { mode = "0700"; user = "root"; group = "root"; };
    "/root/.claude/projects"."L+".argument = "/mnt/share/.claude/projects";
    "/root/.claude/history.jsonl"."L+".argument = "/mnt/share/.claude/history.jsonl";
    "/root/.claude/file-history"."L+".argument = "/mnt/share/.claude/file-history";
    "/root/.claude/plans"."L+".argument = "/mnt/share/.claude/plans";
    "/root/.claude.json".f = {
      mode = "0600"; user = "root"; group = "root";
      argument = builtins.toJSON {
        hasCompletedOnboarding = true;
        projects = {
          "/mnt/share".hasTrustDialogAccepted = true;
        };
      };
    };
    "/root/.claude/settings.json".f = {
      mode = "0600"; user = "root"; group = "root";
      argument = builtins.toJSON {
        permissions.defaultMode = "bypassPermissions";
        skipDangerousModePermissionPrompt = true;
      };
    };
  };
  environment.variables.IS_SANDBOX = "1";
  systemd.tmpfiles.settings."10-claude"."/root/.claude/CLAUDE.md".C = {
    argument = "${pkgs.writeText "CLAUDE.md" ''
      # Environment
      - You are running inside a disposable NixOS VM (Incus), as root.
      - There is no apt/dnf. For a tool needed once, use `nix-shell -p <pkg> --run '<cmd>'`.
      - Permanent packages go into /mnt/share/additions.nix, applied with `nixos-rebuild switch`.
        You're allowed to install software and rebuild the OS yourself if the task requires it.
      - Binaries live in /run/current-system/sw/bin; /usr/bin is mostly empty.
      - /mnt/share/ is a folder shared from the host. Files there are the user's real files;
        everything else in the VM can be freely changed or deleted.
    ''}";
  };
}
