# NVIDIA GPU via the Windows driver + llama.cpp with CUDA
# + llama-server as a systemd user service for agent, and an `oc` command.
#
# The GPU driver comes from Windows (/usr/lib/wsl/lib); do not install a Linux
# NVIDIA driver.
#
# Test as agent:
#   nvidia-smi
#   llama-server --list-devices
#   llama-cli -hf Qwen/Qwen3-0.6B-GGUF:Q8_0 -ngl 99 -p "Hello" -n 64
#
# Service usage (as agent):
#   oc                                    # start server if needed, then opencode
#   systemctl --user start llama-server
#   systemctl --user stop llama-server    # frees the VRAM
#   systemctl --user status llama-server
#   journalctl --user -u llama-server -f
#
# The service does not start on its own; see `wantedBy` below to start it at login.
# `alias` and `context` must match opencode.nix (model key and limit.context).

{ pkgs, ... }:

let
  # If a model fails with "unknown model architecture", this llama.cpp is too old:
  # use llama-cpp from nixpkgs-unstable or github:ggml-org/llama.cpp#cuda instead.
  llamaCpp = pkgs.llama-cpp.override { cudaSupport = true; };

  # Server settings
  modelPath = "%h/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf";  # %h = home dir
  alias = "qwen3.8-27b";
  context = "65536";
  port = "8080";

  # nvidia-smi from Windows is a generic Linux binary; run it via the Nix loader.
  nvidiaSmi = pkgs.writeShellScriptBin "nvidia-smi" ''
    export LD_LIBRARY_PATH=/usr/lib/wsl/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 /usr/lib/wsl/lib/nvidia-smi "$@"
  '';

  # Start llama-server if needed, wait until it is ready, then run opencode.
  oc = pkgs.writeShellScriptBin "oc" ''
    systemctl --user start llama-server
    echo "waiting for llama-server ..."
    until ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${port}/health >/dev/null; do
      if ! systemctl --user is-active --quiet llama-server; then
        echo "llama-server failed; see: journalctl --user -u llama-server" >&2
        exit 1
      fi
      sleep 1
    done
    exec opencode "$@"
  '';
in
{
  ##########################################################################
  # GPU
  ##########################################################################
  # CUDA binary cache (CUDA packages are not on cache.nixos.org).
  # On the very first build, pass it via --option (see configuration.nix).
  nix.settings = {
    substituters = [ "https://cache.nixos-cuda.org" ];
    trusted-public-keys = [
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    ];
  };

  wsl.useWindowsDriver = true;
  hardware.graphics.enable = true;
  nixpkgs.config.allowUnfree = true;   # CUDA is unfree

  # libcuda.so.1 lives in /usr/lib/wsl/lib; without this llama.cpp reports
  # "CUDA driver version is insufficient for CUDA runtime version".
  environment.sessionVariables.LD_LIBRARY_PATH = [ "/usr/lib/wsl/lib" ];

  # Make sure the wrapper wins over /usr/lib/wsl/lib/nvidia-smi in PATH.
  environment.shellAliases.nvidia-smi = "${nvidiaSmi}/bin/nvidia-smi";

  # Alternative to the wrapper: run generic Linux binaries system-wide
  # (less strict; foreign binaries are not tracked by Nix).
  # programs.nix-ld.enable = true;

  ##########################################################################
  # llama.cpp
  ##########################################################################
  environment.systemPackages = [
    llamaCpp
    nvidiaSmi
    oc
  ];

  systemd.user.services.llama-server = {
    description = "llama.cpp server (local model for opencode)";
    unitConfig.ConditionUser = "agent";   # never start in root's user session

    # Start automatically when agent logs in (keeps ~20 GB VRAM in use):
    # wantedBy = [ "default.target" ];

    # User services do not reliably get session variables; set the driver path here.
    environment.LD_LIBRARY_PATH = "/usr/lib/wsl/lib";

    serviceConfig = {
      ExecStart = builtins.concatStringsSep " " [
        "${llamaCpp}/bin/llama-server"
        "-m ${modelPath}"
        "--alias ${alias}"
        "-ngl 99 -c ${context} --jinja"
        "--host 127.0.0.1 --port ${port}"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
