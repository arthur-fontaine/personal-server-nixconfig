# DigUp needs Xcode 26 to build, so this unpacks the signed release instead.
# Its `digup` CLI ships inside the app, as the indexing helper.
{ stdenvNoCC, fetchurl, _7zz, makeWrapper }:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "digup";
  version = "0.6.2";

  src = fetchurl {
    url = "https://github.com/ARahim3/DigUp/releases/download/v${finalAttrs.version}/DigUp-${finalAttrs.version}.dmg";
    hash = "sha256-BDAzvb4MfF/LVlRXEcGdDM8sub5YeY0OR/fDXpAsxf0=";
  };

  nativeBuildInputs = [ _7zz makeWrapper ];
  sourceRoot = ".";
  unpackPhase = ''
    7zz x -snl "$src" >/dev/null
    # 7zz writes extended attributes out as "name:attr" files.
    find . -name "*:*" -delete
  '';

  # Rewriting anything inside the bundle would break its signature.
  dontFixup = true;

  installPhase = ''
    app="$(find . -maxdepth 2 -name DigUp.app -type d | head -1)"
    mkdir -p $out/Applications $out/bin
    cp -R "$app" $out/Applications/
    makeWrapper $out/Applications/DigUp.app/Contents/Helpers/digup $out/bin/digup
  '';

  meta = {
    description = "Search files by what they contain, show or say";
    homepage = "https://github.com/ARahim3/DigUp";
    platforms = [ "aarch64-darwin" ];
    mainProgram = "digup";
  };
})
