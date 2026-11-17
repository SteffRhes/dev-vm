{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    htop
  ];
  virtualisation.docker.enable = true;
  programs.git.config.user.email = "stefan.resch@oeaw.ac.at";
}

