# GUI actions through cua-driver
# (https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/features/computer-use.md).
# The driver is Hermes' pinned build, or a newer release while that one is
# older (pkgs/cua-driver.nix); its signed CuaDriver.app keeps the
# Accessibility and Screen Recording grants across updates (MANUAL_SETUP.md).
{ lib, pkgs, ... }:
let
  # The copy in /Applications (modules/hermes/system/applications.nix), which
  # macOS can launch by name.
  driver = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver";
  # Hermes' computer_use only speaks the driver it pins. With a newer one, its
  # clicks never landed (by element: "unknown argument element_index"; by
  # pixel: "No screenshot of window … get_window_state"), so Hermes drives the
  # driver's own MCP tools instead, which match it by construction, as
  # fast-act does. Once Hermes pins a driver as new, this goes with it.
  native = !(pkgs.cua-driver.hermesComputerUse or true);
in
{
  services.hermes-agent = {
    environment.HERMES_CUA_DRIVER_CMD = driver;

    settings = {
      computer_use = {
        permission_mode = "standard";
        # The overlay redraw loop can peg a core when idle.
        no_overlay = true;
        cua_telemetry = false;
      };
    } // lib.optionalAttrs native {
      # Its skill (computer-use) goes too: ./skills.nix. settings is free-form,
      # where mkIf is not resolved.
      agent.disabled_toolsets = [ "computer_use" ];
    };

    mcpServers = lib.mkIf native {
      cua = {
        command = driver;
        args = [ "mcp" ];
        # What computer_use.cua_telemetry = false sets for Hermes' own spawns
        # (tools/computer_use/cua_backend.py, cua_driver_child_env).
        env.CUA_DRIVER_RS_TELEMETRY_ENABLED = "0";
        # Web pages have Hermes' browser and fast-act; the rest is the driver's
        # own upkeep (updates, extensions, recordings, its cursor's looks) or
        # deprecated aliases.
        tools.exclude = [
          "browser_*"
          "page"
          "check_for_update"
          "install_*"
          "*_recording*"
          "replay_trajectory"
          "*agent_cursor*"
          "escalate_session"
          "get_session_state"
        ];
      };
    };
  };
}
