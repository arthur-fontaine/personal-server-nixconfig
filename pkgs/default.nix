# The packages nixpkgs lacks, as an overlay.
{ inputs }:
final: prev: {
  display-brightness = final.callPackage ./display-brightness { };
  fsearch = final.callPackage ./fsearch.nix { };
  digup = final.callPackage ./digup.nix { };
  hermes-whatsapp-bridge = final.callPackage ./whatsapp-bridge.nix {
    hermes-agent-src = inputs.hermes-agent;
  };
}
