# The packages nixpkgs lacks, as an overlay.
{ inputs }:
final: prev:
let
  system = final.stdenv.hostPlatform.system;
in
{
  display-brightness = final.callPackage ./display-brightness { };
  fsearch = final.callPackage ./fsearch.nix { };
  digup = final.callPackage ./digup.nix { };
  hermes-whatsapp-bridge = final.callPackage ./whatsapp-bridge.nix {
    hermes-agent-src = inputs.hermes-agent;
  };
  # Hermes' pinned computer-use driver (its pm/lock.json).
  cua-driver = inputs.hermes-agent.packages.${system}.pm-cua-driver;
  # uzu's CLI, with its OpenAI-compatible `server`.
  mirai = inputs.uzu.packages.${system}.mirai;
}
