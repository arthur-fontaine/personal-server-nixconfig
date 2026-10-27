# Features a headless server has no use for, turned off to save power.
{ config, lib, pkgs, ... }:
{
  environment.systemPackages = [ pkgs.blueutil ];

  system.activationScripts.postActivation.text = ''
    # Spotlight indexing is the largest idle consumer; fsearch and DigUp
    # replace it for the agent.
    /usr/bin/mdutil -a -i off >/dev/null 2>&1 || true

    ${lib.optionalString config.server.energy.disableBluetooth ''
      ${pkgs.blueutil}/bin/blueutil --power 0 || true
    ''}

    # No startup chime.
    /usr/sbin/nvram StartupMute=%01 || true
  '';

  # For the administrator; the Hermes account gets the same from home-manager.
  system.defaults.CustomUserPreferences = {
    "com.apple.assistant.support"."Assistant Enabled" = false;
    "com.apple.Siri" = {
      StatusMenuVisible = false;
      VoiceTriggerUserEnabled = false;
    };
  };

  # No macOS or App Store downloads in the background. Security responses
  # (XProtect, configuration data) stay on.
  system.defaults.CustomSystemPreferences = {
    "/Library/Preferences/com.apple.SoftwareUpdate" = {
      AutomaticDownload = false;
      CriticalUpdateInstall = true;
      ConfigDataInstall = true;
    };
    "/Library/Preferences/com.apple.commerce".AutoUpdate = false;
  };
}
