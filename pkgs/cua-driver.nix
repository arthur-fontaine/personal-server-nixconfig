# cua-driver, newer than the one Hermes pins: its jev-use loop (decision
# models choosing the next action, examples/jev-use) needs Cua Driver
# 0.23.2 or later (https://cua.ai/docs/how-to-guides/driver/jev-use).
# The release's signed tree as it is, laid out like Hermes' own package
# (nix/pm-packages.nix in its source): CuaDriver.app keeps its signature, so
# macOS keeps the grants it was given. pkgs/default.nix uses it only while
# Hermes pins an older one.
{ lib, stdenvNoCC, fetchzip }:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cua-driver";
  version = "0.38.0";

  src = fetchzip {
    url = "https://github.com/trycua/cua/releases/download/cua-driver-rs-v${finalAttrs.version}/cua-driver-rs-${finalAttrs.version}-darwin-universal.tar.gz";
    hash = "sha256-JrSYevQTt+TF5WGgG5OIluXC4K+5Lk4ydY5KB5Fpksk=";
  };

  dontBuild = true;
  dontConfigure = true;
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/bin
    cp -R . $out/
    ln -s $out/cua-driver $out/bin/cua-driver
  '';

  # Hermes' computer_use tool speaks the contract of the driver it pins
  # (0.21): this one's click refuses its element_index and takes x,y only off
  # a get_window_state read, so every click failed. Hermes then gets this
  # driver's own tools instead (modules/hermes/agent/computer-use.nix).
  passthru.hermesComputerUse = false;

  meta = {
    description = "Cua's computer-use driver";
    homepage = "https://github.com/trycua/cua";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "cua-driver";
  };
})
