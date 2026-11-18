{ modulesPath, config, lib, pkgs, ... }:

{
  systemd.services =
    let
      common = {
        wants = [ "network-online.target" ];
        restartIfChanged = false;
        environment = config.nix.envVars // {
          inherit (config.environment.sessionVariables) NIX_PATH;
          HOME = "/root";
        };
        path = [ config.system.build.nixos-rebuild config.nix.package config.systemd.package pkgs.git pkgs.coreutils ];
        serviceConfig.Type = "oneshot";
        script = ''
          # skip if started by an ongoing switch (e.g. a manual nixos-rebuild)
          if systemctl is-active --quiet nixos-rebuild-switch-to-configuration.service; then
            echo "another nixos-rebuild switch is running, skipping"
            exit 0
          fi
          nixos-rebuild switch
        '';
      };
    in
    {
      rebuild-on-boot = common // {
        description = "Rebuild NixOS on boot";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
      };
    };
}
