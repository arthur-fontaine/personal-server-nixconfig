# Peter Steinberger's macOS CLIs, from their signed releases: building them
# takes Xcode. Each archive is kept as it is, next to the binary (resource
# bundles, dylibs), since rewriting anything would break the signature.
{ lib, stdenvNoCC, fetchurl, unzip, makeWrapper }:
let
  release = { pname, version, repo, asset, hash, description }:
    stdenvNoCC.mkDerivation {
      inherit pname version;
      src = fetchurl {
        url = "https://github.com/steipete/${repo}/releases/download/v${version}/${asset}";
        inherit hash;
      };
      nativeBuildInputs = [ unzip makeWrapper ];
      sourceRoot = ".";
      dontFixup = true;
      installPhase = ''
        dir="$(dirname "$(find . -type f -name ${pname} | head -1)")"
        mkdir -p $out/libexec $out/bin
        cp -R "$dir" $out/libexec/${pname}
        makeWrapper $out/libexec/${pname}/${pname} $out/bin/${pname}
      '';
      meta = {
        inherit description;
        homepage = "https://github.com/steipete/${repo}";
        license = lib.licenses.mit;
        platforms = [ "aarch64-darwin" ];
        mainProgram = pname;
      };
    };
in
{
  imsg = release {
    pname = "imsg";
    version = "0.20.0";
    repo = "imsg";
    asset = "imsg-macos.zip";
    hash = "sha256-k3B5NIXLn5rgYChr6XjH6XHb15lhMBf93NkT0TZty3U=";
    description = "Read and send iMessage and SMS from Messages.app";
  };
  remindctl = release {
    pname = "remindctl";
    version = "0.3.9";
    repo = "remindctl";
    asset = "remindctl-macos.zip";
    hash = "sha256-bbaVeL7zbIPVxAVgEDoQAmsf0uz8RcTvaV7uCt5VJ60=";
    description = "Apple Reminders from the terminal";
  };
  peekaboo = release {
    pname = "peekaboo";
    version = "4.9.7";
    repo = "Peekaboo";
    asset = "peekaboo-macos-arm64.tar.gz";
    hash = "sha256-FHqBqbMcG3t71fcgZ0rX3nGVFpgTjTeWeWeKnM/dCjg=";
    description = "macOS screenshots and UI automation for agents";
  };
}
