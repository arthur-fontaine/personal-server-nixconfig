# The macOS server itself: Nix, power, SSH and the features it turns off.
{ pkgs, username, inputs, ... }:
{
  imports = [
    ./options
    ./nix.nix
    ./power.nix
    ./ssh.nix
    ./quiet.nix
  ];

  nixpkgs.overlays = [ (import ../../pkgs { inherit inputs; }) ];

  system.primaryUser = username;
  users.users.${username}.shell = pkgs.zsh;

  programs.zsh.enable = true;
  environment.shells = [ pkgs.zsh ];
  environment.systemPackages = with pkgs; [ git ];

  system.stateVersion = 6;
}
