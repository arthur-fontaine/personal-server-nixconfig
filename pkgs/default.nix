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
  imcp = final.callPackage ./apple/imcp.nix { };
  wacli = final.callPackage ./wacli.nix { };
  hermes-homeassistant = final.callPackage ./hermes-homeassistant.nix { };
  # Hermes' pinned computer-use driver (its pm/lock.json), or ./cua-driver.nix
  # while that one is older: once Hermes pins a newer driver, its own is used
  # again and ./cua-driver.nix can go.
  cua-driver =
    let
      pinned = inputs.hermes-agent.packages.${system}.pm-cua-driver;
      ours = final.callPackage ./cua-driver.nix { };
    in
    if final.lib.versionAtLeast pinned.version ours.version then pinned else ours;
  # uzu's CLI, with its OpenAI-compatible `server`.
  mirai = inputs.uzu.packages.${system}.mirai;
}
