# The Hermes account's GUI session, which macOS logs in at boot: a live,
# unlit screen for computer use, the search daemons, and quiet defaults.
# launchd.nix starts its agents only once that session exists.
{ ... }:
{
  imports = [
    ./launchd.nix
    ./full-disk.nix
    ./restart.nix
    ./setup-assistant.nix
    ./setup.nix
    ./display.nix
    ./search.nix
    ./defaults.nix
  ];
}
