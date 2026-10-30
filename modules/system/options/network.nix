{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.localNetwork.allowed = mkOption {
    type = types.listOf types.str;
    # Private IPv4, link-local, and IPv6 unique-local and link-local.
    default = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16" "fc00::/7" "fe80::/10" ];
    example = [ "192.168.1.0/24" ];
    description = ''
      Networks (CIDR) every program may reach without macOS' Local Network
      permission. macOS asks it of each app and launchd agent, Hermes'
      included, in a dialog nobody is at this screen to answer, and blocks
      them meanwhile: Home Assistant and the rest of your network would be
      out of reach. [] puts the dialogs back. Takes effect after a restart.
    '';
  };
}
