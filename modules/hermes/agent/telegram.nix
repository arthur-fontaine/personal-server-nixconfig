# Telegram, through a bot of your own
# (https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/messaging/telegram.md).
# The root of your DM with the bot is the main chat. With BotFather's Threaded
# Mode and "Disallow users to create new threads", its topics are the sub-chats
# the bot opens with `/sub new`; each group and group topic is one too.
# The bot token and your user id (TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS)
# are in the secrets file, written by scripts/bootstrap-macos.sh.
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

    # Hermes' core commands (69) overflow the 60-entry menu and come before
    # plugin commands, which would leave /sub out of Telegram's completion.
    platforms.telegram.extra.command_menu.priority = [ "sub" ];
  };
}
