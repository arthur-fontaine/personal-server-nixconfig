# fsearch's daemon keeps its index live, so name searches answer at once. It
# runs under the launcher too, so Full Disk Access lets it index the whole disk.
# DigUp indexes on demand (`digup index`), so it needs no daemon.
{ lib, pkgs, server, ... }:
{
  launchd.agents.fsearch = {
    enable = true;
    config = {
      ProgramArguments = [ server.hermes.access.launcher (lib.getExe pkgs.fsearch) "serve" ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      LowPriorityIO = true;
      Nice = 10;
    };
  };
}
