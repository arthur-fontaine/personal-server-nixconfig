# GUI actions through cua-driver
# (https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/features/computer-use.md).
# The driver is Hermes' pinned build; its signed CuaDriver.app keeps the
# Accessibility and Screen Recording grants across updates (MANUAL_SETUP.md).
{ pkgs, ... }:
{
  services.hermes-agent = {
    environment.HERMES_CUA_DRIVER_CMD = "${pkgs.cua-driver}/CuaDriver.app/Contents/MacOS/cua-driver";

    settings.computer_use = {
      permission_mode = "standard";
      # The overlay redraw loop can peg a core when idle.
      no_overlay = true;
      cua_telemetry = false;
    };
  };
}
