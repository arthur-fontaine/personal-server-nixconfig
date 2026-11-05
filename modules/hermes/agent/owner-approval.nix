# The shared "ask the owner with Telegram buttons" helper
# (../plugins/owner_approval): what a plugin asks outside a turn (the sandbox's
# network and host actions) goes through it. Listed in plugins.enabled by
# memory.nix, which holds that list.
{ pkgs, ... }:
{
  services.hermes-agent.extraPlugins = [
    (pkgs.runCommand "hermes-plugin-owner-approval" { } ''
      cp -R ${../plugins/owner_approval} $out
    '')
  ];
}
