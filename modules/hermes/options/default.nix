# Everything about Hermes is under `server.hermes`.
{ ... }:
{
  imports = [
    ./agent.nix
    ./memory.nix
    ./subchats.nix
    ./access.nix
  ];
}
