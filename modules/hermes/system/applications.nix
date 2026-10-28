# Apps Hermes uses, copied from the Nix store into /Applications. Launch
# Services finds only apps it has registered there (`open -a`, the apps' own
# helpers), and macOS gives each app's permissions to the bundle: a copy, not
# a link, keeps its signature and those grants. Each is replaced only when
# Nix pins another version.
{ config, lib, pkgs, ... }:
let
  apps = {
    # Computer use: `cua-driver permissions grant` and Hermes start it by name.
    "CuaDriver.app" = "${pkgs.cua-driver}/CuaDriver.app";
    # Apple's apps over MCP (modules/hermes/agent/apple.nix).
    "iMCP.app" = "${pkgs.imcp}/Applications/iMCP.app";
  };
  plist = "Contents/Info.plist";
  lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
in
lib.mkIf config.server.hermes.enable {
  system.activationScripts.postActivation.text = ''
    version() { /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$1/${plist}" 2>/dev/null || true; }
  '' + lib.concatStrings (lib.mapAttrsToList (name: source: ''
    if [ "$(version /Applications/${name})" != "$(version ${source})" ]; then
      echo "installing /Applications/${name} $(version ${source})..." >&2
      rm -rf /Applications/${name}
      /usr/bin/ditto ${source} /Applications/${name}
      chown -R root:wheel /Applications/${name}
      ${lsregister} -f /Applications/${name} || true
    fi
  '') apps);
}
