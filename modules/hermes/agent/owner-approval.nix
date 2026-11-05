# The shared "ask the owner with Telegram buttons" helper
# (../plugins/owner_approval): what a plugin asks outside a turn (the sandbox's
# network and host actions) goes through it, and so do the events' proposals
# (its `propose` tool, events.nix). Listed in plugins.enabled by memory.nix,
# which holds that list.
{ pkgs, ... }:
{
  services.hermes-agent = {
    extraPlugins = [
      (pkgs.runCommand "hermes-plugin-owner-approval" { } ''
        cp -R ${../plugins/owner_approval} $out
      '')
    ];
    # A tap on a proposal continues the main chat as the user's turn
    # (PluginContext.inject_message, hermes_cli/plugins_injection.py).
    settings.plugins.entries.owner_approval.allow_gateway_injection = true;
  };
}
