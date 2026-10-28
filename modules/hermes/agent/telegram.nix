# Telegram, through a bot of your own
# (https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/messaging/telegram.md).
# Your DM with the bot is the main chat: its root, or with BotFather's Threaded
# Mode, its "Main" topic (server.hermes.telegram.mainTopic). Every other topic,
# each group and each group topic is a sub-chat.
# The bot token and your user id (TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS)
# are in the secrets file, written by scripts/bootstrap-macos.sh.
{ lib, server, ... }:
let
  main = server.hermes.telegram.mainTopic;
in
{
  # Connect to api.telegram.org directly. The fallback-IP discovery (for
  # networks that block Telegram) stalled the first connection here; the
  # Telegram guide suggests this switch when that path is unhealthy.
  services.hermes-agent.environment.HERMES_TELEGRAM_DISABLE_FALLBACK_IPS = "true";

  services.hermes-agent.settings = {
    # One session per group or topic, not per participant: unii reads the
    # sub-chat from the session key, which then never ends with a user id.
    group_sessions_per_user = false;

    telegram = {
      # Groups are sub-chats with the owner only: answer every message.
      require_mention = false;
    };

    # The DM's main topic, declared so Hermes knows it and never renames it
    # (its id is set, so Hermes does not create it again).
    platforms.telegram.extra.dm_topics = lib.optional (main != null) {
      chat_id = lib.toInt main.chatId;
      topics = [{ name = "Main"; thread_id = main.threadId; }];
    };
  };
}
