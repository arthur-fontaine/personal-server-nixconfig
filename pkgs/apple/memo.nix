# Apple Notes from the terminal (the apple-notes skill's CLI). Its wheel is
# pure Python; it drives Notes.app through AppleScript.
{ lib, python313Packages, fetchurl }:
python313Packages.buildPythonApplication rec {
  pname = "memo";
  version = "0.6.2";
  format = "wheel";
  src = fetchurl {
    url = "https://github.com/antoniorodr/memo/releases/download/v${version}/memo-${version}-py3-none-any.whl";
    hash = "sha256-ig/6pvMV97/bF23O3CqjvjkddDMcTmrgw9O/ge1SPOM=";
  };
  dependencies = with python313Packages; [ chardet click html2text mistune urllib3 ];
  # It wants chardet 7, nixpkgs has 6; it only calls chardet.detect, in both.
  pythonRelaxDeps = [ "chardet" ];
  meta = {
    description = "Apple Notes and Reminders from the terminal";
    homepage = "https://github.com/antoniorodr/memo";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "memo";
  };
}
