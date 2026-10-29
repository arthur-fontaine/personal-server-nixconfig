{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  source = description: default: mkOption { type = types.bool; inherit default description; };
  # An external service's events follow its integration (integrations.nix).
  integration = name: description: mkOption {
    type = types.bool;
    default = config.server.hermes.integrations.${name}.enable;
    defaultText = lib.literalExpression "config.server.hermes.integrations.${name}.enable";
    inherit description;
  };
in
{
  options.server.hermes.events = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Let Hermes write first: when something may call for you (an
        invitation, a question, a plan), it checks what it can (your calendar,
        the place) and proposes what to do in the main chat. docs/events.md.
      '';
    };

    whatsapp = integration "whatsapp" "Incoming WhatsApp messages (wacli's webhook).";
    imessage = source "Incoming iMessages and SMS (imsg watch)." true;
    instagram = integration "instagram" "Instagram's notifications, in Hermes' always-open Chrome.";
    discord = integration "discord" "Discord's notifications, from a Discord tab kept open in that Chrome.";
    homeassistant = integration "homeassistant" "Home Assistant's state changes, in server.hermes.homeassistant's watched domains and entities.";
    homekit = integration "homekit" "HomeKit accessory changes HomeClaw is set to report (its triggers).";
    calendar = source "New events in the calendar, and events starting soon (iMCP)." true;
    mail = source "New unread mail (iMCP, once its Mail folder access is granted)." true;
    reminders = source "Reminders falling due (remindctl)." true;
    calls = source "Missed calls (the call history iCloud syncs to this Mac)." true;
    github = integration "github" ''
      GitHub notifications, with their own classic token (the notifications
      scope; fine-grained tokens cannot read them), GITHUB_NOTIFICATIONS_TOKEN
      in the secrets file: the bootstrap asks for it. Without it, skipped.
    '';
    runpod = integration "runpod" "RunPod pods left running (2, 6, 12, 24, 48 hours).";
    system = source "This Mac: low disk, power cuts, a service down, new logins. Sent as is." true;

    files = mkOption {
      type = types.listOf types.str;
      default = [ "~/Downloads" "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads" ];
      description = "Folders whose new files are events (Hermes' own ~, and its iCloud Drive). [] turns it off.";
    };

    batchSeconds = mkOption {
      type = types.ints.positive;
      default = 45;
      description = ''
        A chat's messages gather into one event until it has been quiet this
        long ("bubble tea?", then "ce soir"); an answer you send in the
        meantime means nothing to propose.
      '';
    };
    maxBatchSeconds = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "A chat that never goes quiet is still sent this long after its first message.";
    };
    maxAgeSeconds = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "Older messages are history (a replay, a sync), not events.";
    };
    port = mkOption {
      type = types.port;
      default = 8645;
      description = "The daemon's loopback port, where wacli and HomeClaw post.";
    };
    webhookPort = mkOption {
      type = types.port;
      default = 8644;
      description = "Hermes' webhook server, on loopback.";
    };
  };
}
