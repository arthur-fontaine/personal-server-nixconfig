# fsearch's daemon keeps its index live, so name searches answer at once.
# DigUp indexes on demand (`digup index`), so it needs no daemon.
{ lib, pkgs, ... }:
{
  launchd.agents.fsearch = {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe pkgs.fsearch) "serve" ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      LowPriorityIO = true;
      Nice = 10;
    };
  };
}
