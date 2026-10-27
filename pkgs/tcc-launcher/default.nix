{ stdenv }:
stdenv.mkDerivation {
  pname = "tcc-launcher";
  version = "1";
  src = ./.;
  dontConfigure = true;
  buildPhase = ''
    $CC -O2 -Wall -o tcc-launcher main.c
  '';
  installPhase = ''
    install -Dm755 tcc-launcher $out/bin/tcc-launcher
  '';
  meta.mainProgram = "tcc-launcher";
}
