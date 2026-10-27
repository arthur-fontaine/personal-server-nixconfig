# The packages nixpkgs lacks, as an overlay.
{ inputs }:
final: prev: {
  display-brightness = final.callPackage ./display-brightness { };
}
