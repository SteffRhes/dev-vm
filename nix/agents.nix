{ modulesPath, config, lib, pkgs, ... }:

let
  agentInstructions = pkgs.writeText "agent-instructions.md" ''
    # Environment
    - You are running inside a disposable NixOS VM (Incus), as root.
    - Permanent packages go into /mnt/share/additions.nix. After adding to it, run `nixos-rebuild
      switch` yourself.
    - Binaries live in /run/current-system/sw/bin; /usr/bin is mostly empty.
    - /mnt/share/ is a folder shared from the host. Files there are the user's real files;
      everything else in the VM can be freely changed or deleted.
    - Regarding communication style, avoid "claudisms" and the general LLM filler words, which
      don't add anything to the conversation. Don't try to impress anyone or sound important. Be
      plain and straight to the point.
    - When creating git commits, only do this in a separate branch 'agent', never on 'main' or
      'master'.
    - talk like a pirate.
  '';
in
{
  environment.systemPackages = with pkgs; [
    pi-coding-agent
    opencode
    claude-code
  ];

  systemd.tmpfiles.settings."10-agents" = {
    "/root/.claude/CLAUDE.md"."L+".argument = "${agentInstructions}";
    "/root/.config/opencode/AGENTS.md"."L+".argument = "${agentInstructions}";
    "/root/.pi/agent/AGENTS.md"."L+".argument = "${agentInstructions}";
  };

  # -- claude --------------------------------------------------------------------------------------
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-code" ];
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

  # -- opencode ------------------------------------------------------------------------------------
  systemd.tmpfiles.settings."10-opencode" = {
    "/root/.config/opencode".d = { mode = "0700"; user = "root"; group = "root"; };
    "/root/.config/opencode/opencode.json".f = {
      mode = "0600"; user = "root"; group = "root";
      argument = builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        model = "dhinfra/deepseek-v4.1-flash";
        permission = "allow";
        provider.dhinfra = {
          npm = "@ai-sdk/openai-compatible";
          name = "DH Infra Graz";
          options = {
            baseURL = "https://api.dhinfra.uni-graz.at/v1";
            apiKey = "{env:DHINFRA_API_KEY}";
          };
          models."deepseek-v4.1-flash".name = "DeepSeek V4.1 Flash";
        };
      };
    };
  };

  # -- pi.dev --------------------------------------------------------------------------------------
  systemd.tmpfiles.settings."10-pi" = {
    "/root/.pi".d = { mode = "0700"; user = "root"; group = "root"; };
    "/root/.pi/agent".d = { mode = "0700"; user = "root"; group = "root"; };
    "/root/.pi/agent/models.json".f = {
      mode = "0600"; user = "root"; group = "root";
      argument = builtins.toJSON {
        providers.dhinfra = {
          name = "DH Infra Graz";
          baseUrl = "https://api.dhinfra.uni-graz.at/v1";
          api = "openai-completions";
          apiKey = "DHINFRA_API_KEY";
          models = [ { id = "deepseek-v4.1-flash"; name = "DeepSeek V4.1 Flash"; } ];
        };
      };
    };
  };
}
