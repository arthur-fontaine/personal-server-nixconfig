# Hermes keeps its room tidy (../system/access/freeze.py writes the space
# report): at its next turn it is told of the big folders it created that
# are about to freeze, so it deletes its scratch while it still can
# (../plugins/space). Listed in plugins.enabled by memory.nix, which holds
# that list.
{ pkgs, server, ... }:
{
  services.hermes-agent = {
    extraPlugins = [
      (pkgs.runCommand "hermes-plugin-space" { } ''
        cp -R ${../plugins/space} $out
      '')
    ];
    hermesHomeFiles."space/config.json" = builtins.toJSON {
      report = "/var/db/hermes-space/report.json";
      home = server.hermes.home;
      notice_bytes = server.hermes.access.space.noticeBytes;
      notice_window = server.hermes.access.space.noticeWindow;
    };
  };
}
