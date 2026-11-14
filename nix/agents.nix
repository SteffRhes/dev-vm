{ modulesPath, config, lib, pkgs, ... }:

{
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-code" ];

  environment.systemPackages = [ pkgs.claude-code ];
}
