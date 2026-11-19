{ modulesPath, config, lib, pkgs, ... }:

let
  # OpenCode comes from nixos-unstable: the version in nixos-26.05 segfaults at startup.
  # Requires the channel (as root, once; setup.ps1 does this):
  #   nix-channel --add https://channels.nixos.org/nixos-unstable nixos-unstable
  #   nix-channel --update
  # Updating OpenCode later: `nix-channel --update` + `nixos-rebuild switch` (as root).
  unstable = import <nixos-unstable> { system = pkgs.stdenv.hostPlatform.system; };

  # All agents run as "agent"; their configs live in its home.
  user = "agent";
  group = config.users.users.${user}.group;
  home = config.users.users.${user}.home;

  agentInstructions = pkgs.writeText "agent-instructions.md" ''
    # Environment
    - You are running inside a disposable NixOS VM (WSL), as user 'agent'.
    - Binaries live in /run/current-system/sw/bin; /usr/bin is mostly empty.
    - /mnt/aivm/ is a folder shared from the host. Files there are the user's real files;
      everything else in the VM can be freely changed or deleted.
    - Regarding communication style, avoid "claudisms" and the general LLM filler words, which
      don't add anything to the conversation. Don't try to impress anyone or sound important. Be
      plain and straight to the point.
    - When creating git commits, only do this in a separate branch 'agent', never on 'main' or
      'master'.
  '';
in
{
  environment.systemPackages = with pkgs; [
    pi-coding-agent
    unstable.opencode   # see `unstable` above
    claude-code
  ];

  systemd.tmpfiles.settings."10-agents" = {
    # Create ~/.config owned by agent; otherwise tmpfiles would create it as root.
    "${home}/.config".d = { mode = "0700"; inherit user group; };

    "${home}/.claude/CLAUDE.md"."L+".argument = "${agentInstructions}";
    "${home}/.config/opencode/AGENTS.md"."L+".argument = "${agentInstructions}";
    "${home}/.pi/agent/AGENTS.md"."L+".argument = "${agentInstructions}";
  };

  # -- claude --------------------------------------------------------------------------------------
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-code" ];
  systemd.tmpfiles.settings."10-claude" = {
    "${home}/.claude".d = { mode = "0700"; inherit user group; };
    "${home}/.claude/projects"."L+".argument = "/mnt/aivm/.claude/projects";
    "${home}/.claude/history.jsonl"."L+".argument = "/mnt/aivm/.claude/history.jsonl";
    "${home}/.claude/file-history"."L+".argument = "/mnt/aivm/.claude/file-history";
    "${home}/.claude/plans"."L+".argument = "/mnt/aivm/.claude/plans";
    "${home}/.claude.json".f = {
      mode = "0600"; inherit user group;
      argument = builtins.toJSON {
        hasCompletedOnboarding = true;
        projects = {
          "/mnt/aivm".hasTrustDialogAccepted = true;
        };
      };
    };
    "${home}/.claude/settings.json".f = {
      mode = "0600"; inherit user group;
      argument = builtins.toJSON {
        permissions.defaultMode = "bypassPermissions";
        skipDangerousModePermissionPrompt = true;
      };
    };
  };
  environment.variables.IS_SANDBOX = "1";

  # -- opencode ------------------------------------------------------------------------------------
  systemd.tmpfiles.settings."10-opencode" = {
    "${home}/.config/opencode".d = { mode = "0700"; inherit user group; };
    "${home}/.config/opencode/opencode.json".f = {
      mode = "0600"; inherit user group;
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
        # Local llama-server from gpu-llama.nix (select it in OpenCode with /models).
        provider.llamacpp = {
          npm = "@ai-sdk/openai-compatible";
          name = "llama-server (local)";
          options.baseURL = "http://127.0.0.1:8080/v1";   # gpu-llama.nix: port
          models."qwen3.8-27b" = {                         # gpu-llama.nix: alias
            name = "Qwen3.8 27B (local)";
            limit = {
              context = 65536;                             # gpu-llama.nix: context
              output = 8192;
            };
          };
        };
      };
    };
  };

  # -- pi.dev --------------------------------------------------------------------------------------
  systemd.tmpfiles.settings."10-pi" = {
    "${home}/.pi".d = { mode = "0700"; inherit user group; };
    "${home}/.pi/agent".d = { mode = "0700"; inherit user group; };
    "${home}/.pi/agent/models.json".f = {
      mode = "0600"; inherit user group;
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
