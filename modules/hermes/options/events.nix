{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes.events = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Let Hermes write first: when a message may call for you (an
        invitation, a question, a plan), it checks what it can (your calendar,
        the place) and proposes what to do in the main chat. docs/events.md.
      '';
    };
    whatsapp = mkOption {
      type = types.bool;
      default = true;
      description = "Screen incoming WhatsApp messages (wacli's webhook).";
    };
    imessage = mkOption {
      type = types.bool;
      default = true;
      description = "Screen incoming iMessages and SMS (imsg watch).";
    };
    batchSeconds = mkOption {
      type = types.ints.positive;
      default = 60;
      description = ''
        How long a chat's messages are gathered into one event after its first
        one: a burst is one proposal, and an answer you send in the meantime
        means nothing to propose.
      '';
    };
    maxAgeSeconds = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "Older messages are history (a replay, a sync), not events.";
    };
    port = mkOption {
      type = types.port;
      default = 8645;
      description = "The daemon's loopback port, where wacli posts.";
    };
    webhookPort = mkOption {
      type = types.port;
      default = 8644;
      description = "Hermes' webhook server, on loopback.";
    };
  };
}
