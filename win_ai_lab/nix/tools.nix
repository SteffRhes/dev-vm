# Basic tools for all users.

{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  environment.variables.EDITOR = "vim";
}
