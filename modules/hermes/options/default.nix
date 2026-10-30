# Everything about Hermes is under `server.hermes`.
{ ... }:
{
  imports = [
    ./agent.nix
    ./memory.nix
    ./subchats.nix
    ./access.nix
    ./telegram.nix
    ./onepassword.nix
    ./events.nix
    ./integrations.nix
    ./homeassistant.nix
    ./decision.nix
  ];
}
