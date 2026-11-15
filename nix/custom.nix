{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    git
    htop
  ];

  virtualisation.docker.enable = true;
}

