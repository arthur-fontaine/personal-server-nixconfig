{ pkgs, username, ... }:
{
  imports = [
    ../options
    ./nix.nix
    ./server
  ];

  system.primaryUser = username;
  users.users.${username}.shell = pkgs.zsh;

  programs.zsh.enable = true;
  environment.shells = [ pkgs.zsh ];
  environment.systemPackages = with pkgs; [ git ];

  system.stateVersion = 6;
}
