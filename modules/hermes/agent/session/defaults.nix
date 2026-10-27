# The same quiet settings as the administrator's (modules/system/quiet.nix),
# plus what only matters in a session that stays logged in.
{ ... }:
{
  targets.darwin.defaults = {
    "com.apple.assistant.support"."Assistant Enabled" = false;
    "com.apple.Siri" = {
      StatusMenuVisible = false;
      VoiceTriggerUserEnabled = false;
    };
    # No Handoff advertising over Bluetooth/Wi-Fi.
    "com.apple.coreservices.useractivityd" = {
      ActivityAdvertisingAllowed = false;
      ActivityReceivingAllowed = false;
    };
    # No animations to render.
    "com.apple.dock" = {
      autohide = true;
      launchanim = false;
      mineffect = "scale";
    };
    NSGlobalDomain.NSAutomaticWindowAnimationsEnabled = false;
  };

  # No screen saver: it would hide the windows computer use acts on.
  targets.darwin.currentHostDefaults."com.apple.screensaver".idleTime = 0;
}
