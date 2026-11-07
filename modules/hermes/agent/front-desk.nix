# The main chat answers and dispatches; long work runs in background
# subagents (../plugins/front_desk). Listed in plugins.enabled by memory.nix,
# which holds that list. The budget: server.hermes.frontDesk.
{ pkgs, server, ... }:
let
  cfg = server.hermes.frontDesk;
in
{
  services.hermes-agent = {
    extraPlugins = [
      (pkgs.runCommand "hermes-plugin-front-desk" { } ''
        cp -R ${../plugins/front_desk} $out
      '')
    ];
    hermesHomeFiles."front_desk/config.json" = builtins.toJSON {
      inherit (cfg) seconds;
      tool_calls = cfg.toolCalls;
      foreground_seconds = cfg.foregroundSeconds;
    };
  };
}
