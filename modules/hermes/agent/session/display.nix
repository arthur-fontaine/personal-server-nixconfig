# Computer use needs a display that is awake, so keep it awake (caffeinate -d)
# with its backlight off. macOS raises the brightness again on some events, so
# it is set again every ten minutes. The lid must stay open: with it closed the
# built-in display is off and screenshots are black.
{ lib, pkgs, server, ... }:
{
  launchd.agents.caffeinate = {
    enable = true;
    config = {
      ProgramArguments = [ "/usr/bin/caffeinate" "-d" "-i" ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
    };
  };

  launchd.agents.display-brightness = {
    enable = true;
    config = {
      ProgramArguments = [
        (lib.getExe pkgs.display-brightness)
        (toString server.energy.displayBrightness)
      ];
      RunAtLoad = true;
      StartInterval = 600;
      ProcessType = "Background";
    };
  };
}
