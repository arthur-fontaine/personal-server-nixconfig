{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes.telegram.mainTopic = mkOption {
    type = types.nullOr (types.submodule {
      options = {
        chatId = mkOption {
          type = types.str;
          description = "Your DM with the bot: its chat id, which is your Telegram user id.";
        };
        threadId = mkOption {
          type = types.ints.positive;
          description = "The topic's message_thread_id, which createForumTopic returned.";
        };
      };
    });
    default = null;
    description = ''
      With BotFather's Threaded Mode, the topic of your DM with the bot that is
      the main chat; every other topic is a sub-chat. scripts/bootstrap-macos.sh
      creates a "Main" topic and writes this into hosts/local.nix. null: the
      DM's root is the main chat (Threaded Mode off).
    '';
  };
}
