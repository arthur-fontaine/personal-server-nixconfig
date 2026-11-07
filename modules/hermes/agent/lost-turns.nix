# The owner's Telegram turn cut off by a gateway crash settles on its own
# (../plugins/lost_turns): the chat never pauses for /discard. Listed in
# plugins.enabled by memory.nix, which holds that list.
{ pkgs, ... }:
{
  services.hermes-agent = {
    extraPlugins = [
      (pkgs.runCommand "hermes-plugin-lost-turns" { } ''
        cp -R ${../plugins/lost_turns} $out
      '')
    ];
    # One turn for Hermes when nothing was queued behind the lost one
    # (PluginContext.inject_message, hermes_cli/plugins_injection.py).
    settings.plugins.entries.lost_turns.allow_gateway_injection = true;
  };
}
