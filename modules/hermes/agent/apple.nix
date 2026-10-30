# Apple's apps beyond the bundled skills (Messages, Reminders, Notes, Find My:
# tools.nix): iMCP (https://github.com/mattt/iMCP) for Calendar, Contacts,
# Mail, Maps, Music, Shortcuts, Voice Memos and Weather, and, when the HomeKit
# integration is on, HomeClaw (https://github.com/omarshahine/HomeClaw). Both
# are menu bar apps in Hermes' session that hold their own permissions and
# serve MCP.
{ lib, pkgs, server, ... }:
let
  # Copied there by modules/hermes/system/applications.nix.
  imcp = "/Applications/iMCP.app";
  # The App Store's only (HomeKit is not allowed outside it): the bootstrap installs it.
  homeclaw = "/Applications/HomeClaw.app";
  homekit = server.hermes.integrations.homekit.enable;

  # Both apps are sandboxed, so their settings live in their container, which
  # macOS creates at their first launch: until then there is nothing to set.
  # The rebuild runs this, and so does the bootstrap after the first launch.
  appDefaults = pkgs.writeShellScriptBin "hermes-app-defaults" (''
    set_default() {
      local prefs="$HOME/Library/Containers/$1/Data/Library/Preferences"
      [ -d "$prefs" ] || return 0
      /usr/bin/defaults write "$prefs/$1" "$2" "$3" "$4"
    }
    # The skills cover Reminders, Notes and Messages, and do more there.
    set_default co.dododo.iMCP remindersEnabled -bool false
    set_default co.dododo.iMCP notesEnabled -bool false
    set_default co.dododo.iMCP messagesEnabled -bool false
    # Hermes and the events daemon connect without the approval dialog:
    # ["hermes-agent","hermes-events"] as JSON, their MCP client names (Hermes':
    # tools/mcp_tool_transport.py in its source; the daemon's: events/pollers.py).
    set_default co.dododo.iMCP trustedClients -data 5b226865726d65732d6167656e74222c226865726d65732d6576656e7473225d
    # Nix pins the version, and the copy in /Applications is root's anyway.
    set_default co.dododo.iMCP SUEnableAutomaticChecks -bool false
  '' + lib.optionalString homekit ''
    # HomeClaw's MCP over HTTP, off by default.
    set_default com.shahine.homeclaw nativeMCPHTTPEnabled -bool true
  '');

  # `open -W` waits for the app, so launchd restarts it if it crashes.
  menuBarApp = app: {
    enable = true;
    config = {
      ProgramArguments = [ "/bin/sh" "-c" "[ -d ${app} ] || exit 0; exec /usr/bin/open -W -g -a ${app}" ];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Interactive";
    };
  };
in
{
  home.packages = [ appDefaults ];
  home.activation.appleAppDefaults = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # Writing into a container takes Full Disk Access, which the rebuild may
    # lack: the bootstrap and the setup at login write them again, through
    # the launcher.
    run ${appDefaults}/bin/hermes-app-defaults \
      || warnEcho "Could not write iMCP's and HomeClaw's settings; Hermes' setup at login does."
  '';

  launchd.agents = { imcp = menuBarApp imcp; } // lib.optionalAttrs homekit { homeclaw = menuBarApp homeclaw; };

  services.hermes-agent.mcpServers = {
    imcp.command = "${imcp}/Contents/MacOS/imcp-server";
  } // lib.optionalAttrs homekit {
    homeclaw.url = "http://127.0.0.1:9090/mcp";
  };
}
