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
    # Hermes drops what was sent while it was down by default: a message sent
    # during a reboot or a rebuild then gets no answer, and no error either.
    # cli-config.yaml.example: "Set false on hosts that power off".
    platforms.telegram.extra.drop_pending_on_cold_boot = false;

    # Answers appear as they are written: Telegram's native drafts in the main
    # chat (a DM), edited messages in the sub-chats' topics, where Telegram
    # allows no drafts (website/docs/user-guide/messaging/telegram.md,
    # "Streaming transport"). Only the final message notifies.
    streaming = {
      enabled = true;
      transport = "auto";
    };
  };
}
