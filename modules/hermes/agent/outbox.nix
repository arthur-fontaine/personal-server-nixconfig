# A reply that attaches a file the gateway will not send says so instead
# (../plugins/outbox). Listed in plugins.enabled by memory.nix, which holds
# that list. Nothing to configure: the plugin asks the gateway's own policy.
{ pkgs, ... }:
{
  services.hermes-agent = {
    extraPlugins = [
      (pkgs.runCommand "hermes-plugin-outbox" { } ''
        cp -R ${../plugins/outbox} $out
      '')
    ];
  };
}
