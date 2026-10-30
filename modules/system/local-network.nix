# Lets Hermes' launchd agents (and anything it installs) reach the local
# network: macOS exempts daemons, root and Terminal's tools from its Local
# Network permission, not agents. These two defaults are Apple's documented
# switch, read from root's preferences:
# https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy#macOS-considerations
{ config, ... }:
let
  allowed = config.server.localNetwork.allowed;
in
{
  system.defaults.CustomSystemPreferences."com.apple.network.local-network" = {
    AllowedEthernetLocalNetworkAddresses = allowed;
    AllowedWiFiLocalNetworkAddresses = allowed;
  };
}
