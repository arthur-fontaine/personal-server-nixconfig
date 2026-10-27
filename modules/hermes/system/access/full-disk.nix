# Full Disk Access, granted once. macOS ties the grant to one exact binary and
# attributes a process to the program launchd started, so the gateway, fsearch
# and hermes-freeze run under tcc-launcher, copied to a fixed path and left
# alone across Hermes updates. Granting it (scripts/bootstrap-macos.sh) lets
# Hermes read the folders macOS keeps even from root: Desktop, Documents,
# Downloads, Mail, Messages, iCloud.
{ config, lib, pkgs, ... }:
let
  launcher = config.server.hermes.access.launcher;
  version = pkgs.tcc-launcher.version;
in
{
  system.activationScripts.postActivation.text = lib.mkBefore ''
    launcher=${lib.escapeShellArg launcher}
    if [ "$("$launcher" --version 2>/dev/null)" != ${lib.escapeShellArg version} ]; then
      echo "installing $launcher (grant it Full Disk Access again: scripts/bootstrap-macos.sh)" >&2
      mkdir -p "$(dirname "$launcher")"
      chown root:wheel "$(dirname "$launcher")"
      chmod 755 "$(dirname "$launcher")"
      install -m 0755 -o root -g wheel ${lib.getExe pkgs.tcc-launcher} "$launcher"
      /usr/bin/codesign --force --sign - --identifier org.personal-server.hermes-launcher "$launcher"
    fi
  '';
}
