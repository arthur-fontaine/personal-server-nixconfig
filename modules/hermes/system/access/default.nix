# What Hermes may touch, enforced by macOS rather than by the agent:
#
# - read.nix     it reads anything;
# - freeze.nix   it writes or deletes only what it created in the last 24 hours;
# - rebuild.nix  it changes the system only through this repository;
# - secrets.nix  its API keys stay outside the Nix store.
{ ... }:
{
  imports = [
    ./read.nix
    ./secrets.nix
  ];
}
