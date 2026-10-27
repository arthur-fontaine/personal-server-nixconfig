# The Hermes account's GUI session, which macOS logs in at boot: a live,
# unlit screen for computer use, the search daemons, and quiet defaults.
{ ... }:
{
  imports = [
    ./display.nix
  ];
}
