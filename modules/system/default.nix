# The macOS server itself: Nix, power, SSH and the features it turns off.
{ pkgs, username, ... }:
{
  imports = [
    ./options
    ./nix.nix
    ./power.nix
    ./ssh.nix
    ./quiet.nix
  ];

  system.primaryUser = username;
  users.users.${username}.shell = pkgs.zsh;

  programs.zsh.enable = true;
  environment.shells = [ pkgs.zsh ];
  environment.systemPackages = with pkgs; [ git ];

  system.stateVersion = 6;
}
