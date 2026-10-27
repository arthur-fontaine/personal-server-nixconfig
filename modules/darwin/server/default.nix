# The Mac is an always-on server, reached over SSH, that draws as little power
# as it can.
{ ... }:
{
  imports = [
    ./power.nix
    ./ssh.nix
  ];
}
