# CuaDriver.app in /Applications. `cua-driver permissions grant`, and Hermes
# when it starts the driver's daemon, launch the app by name (`open -a
# CuaDriver`), which finds only apps macOS has registered, not one in the Nix
# store. The bundle is copied, not linked, so its signature and the
# Accessibility and Screen Recording grants made to it hold; it is replaced
# only when Hermes pins another driver version.
{ config, lib, pkgs, ... }:
let
  app = "/Applications/CuaDriver.app";
  source = "${pkgs.cua-driver}/CuaDriver.app";
  plist = "Contents/Info.plist";
  lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
in
lib.mkIf config.server.hermes.enable {
  system.activationScripts.postActivation.text = ''
    version() { /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$1/${plist}" 2>/dev/null || true; }
    if [ "$(version ${app})" != "$(version ${source})" ]; then
      echo "installing ${app} $(version ${source})..." >&2
      rm -rf ${app}
      /usr/bin/ditto ${source} ${app}
      chown -R root:wheel ${app}
      ${lsregister} -f ${app} || true
    fi
  '';
}
