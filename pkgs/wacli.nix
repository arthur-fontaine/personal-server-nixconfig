# wacli (https://github.com/openclaw/wacli): WhatsApp from the terminal, as a
# linked device of your number. Its release binary: nixpkgs has none.
{ lib, stdenvNoCC, fetchurl }:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "wacli";
  version = "0.25.1";

  src = fetchurl {
    url = "https://github.com/openclaw/wacli/releases/download/v${finalAttrs.version}/wacli_${finalAttrs.version}_darwin_arm64.tar.gz";
    hash = "sha256-/LJQUuKkxttvtQ7uXujBPd9SQRHkcTDdIuEB6HmZXmc=";
  };

  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    install -Dm755 wacli $out/bin/wacli
  '';

  meta = {
    description = "WhatsApp CLI: sync, search, send";
    homepage = "https://github.com/openclaw/wacli";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "wacli";
  };
})
