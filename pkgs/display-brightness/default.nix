{ stdenv }:
stdenv.mkDerivation {
  pname = "display-brightness";
  version = "1.0.0";
  src = ./.;
  dontConfigure = true;
  buildPhase = ''
    $CC -O2 -Wall -framework CoreGraphics -o display-brightness main.c
  '';
  installPhase = ''
    install -Dm755 display-brightness $out/bin/display-brightness
  '';
  meta.mainProgram = "display-brightness";
}
