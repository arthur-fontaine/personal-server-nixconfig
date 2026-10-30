# GUI actions through cua-driver
# (https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/features/computer-use.md).
# The driver is Hermes' pinned build, or a newer release while that one is
# older (pkgs/cua-driver.nix); its signed CuaDriver.app keeps the
# Accessibility and Screen Recording grants across updates (MANUAL_SETUP.md).
{ ... }:
{
  services.hermes-agent = {
    # The copy in /Applications (modules/hermes/system/applications.nix), which
    # macOS can launch by name.
    environment.HERMES_CUA_DRIVER_CMD = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver";

    settings.computer_use = {
      permission_mode = "standard";
      # The overlay redraw loop can peg a core when idle.
      no_overlay = true;
      cua_telemetry = false;
    };
  };
}
