# iMCP (https://github.com/mattt/iMCP): an MCP server for Calendar, Contacts,
# Mail, Maps, Music, Shortcuts, Voice Memos, Weather and more, as a menu bar
# app that holds those permissions itself. Its signed, notarized release,
# unpacked as it is: rewriting anything would break the signature.
{ lib, stdenvNoCC, fetchurl, unzip }:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "imcp";
  version = "1.8.0";

  src = fetchurl {
    url = "https://github.com/mattt/iMCP/releases/download/${finalAttrs.version}/iMCP.zip";
    hash = "sha256-vKmTqCe4isW/5FDvsVHXw4K9JSSggkli1fA/laE3dtE=";
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/Applications
    cp -R iMCP.app $out/Applications/
  '';

  meta = {
    description = "MCP server for Apple's apps on macOS";
    homepage = "https://github.com/mattt/iMCP";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
  };
})
