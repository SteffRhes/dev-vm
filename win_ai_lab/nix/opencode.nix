# OpenCode (terminal coding agent) connected to the local llama-server.
#
# Start llama-server first (as "agent"), with the same alias and context size:
#   llama-server -m ~/models/<model>.gguf --alias qwen3.8-27b \
#     -ngl 99 -c 65536 --jinja --host 127.0.0.1 --port 8080
# Then, in a project directory:
#   opencode
#
# The config below is system-wide (/etc/opencode/opencode.json, read-only for users).
# A per-project ./opencode.json can still add to it.
#
# OpenCode comes from nixos-unstable: the version in nixos-26.05 crashes at startup.
# Requires the channel (as root, once):
#   nix-channel --add https://channels.nixos.org/nixos-unstable nixos-unstable
#   nix-channel --update
# Updating OpenCode later: `nix-channel --update` + `nixos-rebuild switch` (as root).

{ pkgs, ... }:

let
  unstable = import <nixos-unstable> { system = pkgs.stdenv.hostPlatform.system; };

  opencodeConfig = {
    "$schema" = "https://opencode.ai/config.json";
    model = "llamacpp/qwen3.8-27b";
    enabled_providers = [ "llamacpp" ];   # only the local server, no cloud providers
    share = "disabled";                   # no session sharing links
    autoupdate = false;                   # updates come from nixpkgs

    provider.llamacpp = {
      npm = "@ai-sdk/openai-compatible";
      name = "llama-server (local)";
      options.baseURL = "http://127.0.0.1:8080/v1";
      models."qwen3.8-27b" = {            # must match llama-server --alias
        name = "Qwen3.8 27B (local)";
        limit = {
          context = 65536;                # must match llama-server -c
          output = 8192;
        };
      };
    };
  };
in
{
  environment.systemPackages = [ unstable.opencode ];

  environment.etc."opencode/opencode.json".text = builtins.toJSON opencodeConfig;
  environment.sessionVariables.OPENCODE_CONFIG = "/etc/opencode/opencode.json";
}
