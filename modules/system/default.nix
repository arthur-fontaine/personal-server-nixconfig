# The macOS server itself: Nix, power, SSH and the features it turns off.
{ lib, pkgs, username, inputs, ... }:
{
  imports = [
    ./options
    ./nix.nix
    ./power.nix
    ./ssh.nix
    ./quiet.nix
  ];

  nixpkgs.overlays = [ (import ../../pkgs { inherit inputs; }) ];
  # Free software only, but for these, by name.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "1password-cli" # Hermes' 1Password integration (modules/hermes/agent/onepassword.nix)
  ];

  system.primaryUser = username;
  users.users.${username}.shell = pkgs.zsh;

  programs.zsh.enable = true;
  environment.shells = [ pkgs.zsh ];
  environment.systemPackages = with pkgs; [ git ];

  system.stateVersion = 6;
}
