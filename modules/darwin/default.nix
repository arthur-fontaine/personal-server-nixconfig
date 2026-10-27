{ pkgs, username, ... }:
{
  imports = [
    ./server.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.primaryUser = username;
  users.users.${username}.shell = pkgs.zsh;

  programs.zsh.enable = true;
  environment.shells = [ pkgs.zsh ];
  environment.systemPackages = with pkgs; [ git ];

  system.stateVersion = 6;
}
