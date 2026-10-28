# Computer use needs a display that is awake, so keep it awake (caffeinate -d),
# and turn its backlight down once nobody has touched the Mac for a while
# (server.energy.dimAfter): someone working at it keeps the brightness they
# chose. The lid must stay open: with it closed the built-in display is off and
# screenshots are black.
{ lib, pkgs, server, ... }:
let
  dim = pkgs.writeShellScript "dim-when-idle" ''
    # HIDIdleTime: nanoseconds since the last keyboard, mouse or trackpad input.
    idle=$(/usr/sbin/ioreg -c IOHIDSystem | /usr/bin/awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }')
    if [ "''${idle:-0}" -ge ${toString server.energy.dimAfter} ]; then
      exec ${lib.getExe pkgs.display-brightness} ${toString server.energy.displayBrightness}
    fi
  '';
in
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
      ProgramArguments = [ "${dim}" ];
      RunAtLoad = true;
      StartInterval = 60;
      ProcessType = "Background";
    };
  };
}
