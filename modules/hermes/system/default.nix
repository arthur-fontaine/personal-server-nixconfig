# What Hermes is to macOS: an account, and the rules of what it may touch.
{ ... }:
{
  imports = [
    ./user.nix
    ./access
    ./applications.nix
  ];
}
