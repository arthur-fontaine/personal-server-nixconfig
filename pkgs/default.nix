# The packages nixpkgs lacks, as an overlay.
{ inputs }:
final: prev:
let
  system = final.stdenv.hostPlatform.system;
in
{
  display-brightness = final.callPackage ./display-brightness { };
  tcc-launcher = final.callPackage ./tcc-launcher { };
  fsearch = final.callPackage ./fsearch.nix { };
  digup = final.callPackage ./digup.nix { };
  # The CLIs of Hermes' Apple skills (skills/apple in its source).
  inherit (final.callPackage ./apple/release.nix { }) imsg remindctl peekaboo;
  memo = final.callPackage ./apple/memo.nix { };
  # Hermes' pinned computer-use driver (its pm/lock.json).
  cua-driver = inputs.hermes-agent.packages.${system}.pm-cua-driver;
  # uzu's CLI, with its OpenAI-compatible `server`.
  mirai = inputs.uzu.packages.${system}.mirai;
}
