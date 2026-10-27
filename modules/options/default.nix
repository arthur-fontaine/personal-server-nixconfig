# Every knob of the server lives under `server.*`, one file per topic. Hosts
# override them with a `server = { ... };` attribute (hosts/local.nix.example).
{ ... }:
{
  imports = [
    ./admin.nix
    ./energy.nix
    ./hermes.nix
    ./memory.nix
    ./subchats.nix
    ./access.nix
    ./uzu.nix
  ];
}
