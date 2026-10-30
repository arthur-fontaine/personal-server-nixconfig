# Sourced by scripts/bootstrap-macos.sh, in its order.
# ── Telegram ────────────────────────────────────────────────────────────────

JQ="$(nix build --no-link --print-out-paths nixpkgs#jq.bin)/bin/jq"
# A Bot API call: tg <token> <method> [query string].
tg() { curl -fsS "https://api.telegram.org/bot$1/$2${3:+?$3}"; }
# A Bot API call with form fields: tg_post <token> <method> <name=value>...
tg_post() {
  local token="$1" method="$2" field args=()
  shift 2
  for field in "$@"; do args+=(--data-urlencode "$field"); done
  curl -fsS "https://api.telegram.org/bot$token/$method" "${args[@]}"
}

new_bot_token() {
  local token me
  note "In Telegram, open @BotFather (https://t.me/BotFather) and send:" >&2
  note "  /newbot" >&2
  note "then a display name (e.g. Hermes), then a username ending in \"bot\" (e.g. myname_hermes_bot)." >&2
  note "BotFather answers with the bot's token." >&2
  while :; do
    token="$(gum input --password --header "Bot token from BotFather")"
    # A paste can bring spaces or a line break along.
    token="$(printf '%s' "$token" | tr -d '[:space:]')"
    if ! [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
      warn "That is not a bot token: digits, a colon, then letters, digits, - and _ (${#token} characters read)." >&2
      continue
    fi
    # Not through tg: its -f would hide why Telegram says no.
    if ! me="$(curl -sS "https://api.telegram.org/bot$token/getMe" 2>&1)"; then
      warn "Could not reach Telegram: $me" >&2
      continue
    fi
    if [ "$("$JQ" -r .ok <<< "$me" 2>/dev/null)" = true ]; then
      printf '%s' "$token"
      return
    fi
    warn "Telegram refused the token: $("$JQ" -r '.description // empty' <<< "$me" 2>/dev/null || printf '%s' "$me")" >&2
  done
}

# Your user id, from the first private message the bot receives.
owner_id() {
  local token="$1" bot="$2" offset=0 updates id name last
  note "Open https://t.me/$bot and send it any message (e.g. /start)." >&2
  for _ in $(seq 12); do
    updates="$(tg "$token" getUpdates "timeout=10&offset=$offset")" || continue
    id="$("$JQ" -r '[.result[] | select(.message.chat.type == "private")] | last | .message.from.id // empty' <<< "$updates")"
    name="$("$JQ" -r '[.result[] | select(.message.chat.type == "private")] | last | .message.from.first_name // empty' <<< "$updates")"
    last="$("$JQ" -r '.result | last | .update_id // empty' <<< "$updates")"
    [ -n "$last" ] && offset=$((last + 1))
    if [ -n "$id" ]; then
      tg "$token" getUpdates "offset=$offset" >/dev/null || true
      if gum confirm "Is $name ($id) you?" >&2; then
        printf '%s' "$id"
        return
      fi
    fi
  done
  gum input --header "Your Telegram user id (@userinfobot tells you)"
}

# What only BotFather can switch on, checked through getMe.
botfather_settings() {
  local token="$1" bot="$2" me
  while :; do
    me="$(tg "$token" getMe)"
    if [ "$("$JQ" -r .result.can_read_all_group_messages <<< "$me")" = true ]; then
      ok "Privacy mode is off: groups with @$bot work as sub-chats too"
      break
    fi
    step "Groups, which are the sub-chats"
    note "Send @BotFather, one message at a time:  /setprivacy   @$bot   Disable"
    gum confirm --affirmative "Check again" --negative "Skip" "Done?" || break
  done
  bot_picture "$token" "$bot" "$("$JQ" -r .result.id <<< "$me")"
}

# The Hermes logo as the bot's picture. Only BotFather sets it; the image comes
# from the Hermes source flake.lock pins (its desktop app's icon).
bot_picture() {
  local token="$1" bot="$2" id="$3" src rev picture
  while :; do
    if [ "$(tg "$token" getUserProfilePhotos "user_id=$id&limit=1" | "$JQ" -r .result.total_count)" != 0 ]; then
      ok "@$bot has its picture"
      return
    fi
    if [ -z "${picture:-}" ]; then
      src="$(nix eval --raw --impure --expr "(builtins.getFlake $(nix_string "path:$REPO_DIR")).inputs.hermes-agent.outPath")"
      rev="$("$JQ" -r '.nodes["hermes-agent"].locked.rev' "$REPO_DIR/flake.lock")"
      picture="$HOME/Downloads/hermes-bot-picture.png"
      install -m 0644 "$src/apps/desktop/assets/icon.png" "$picture"
    fi
    step "The bot's picture: the Hermes logo"
    note "Send @BotFather:  /setuserpic   then  @$bot   then the image as a photo:"
    note "  on this Mac: $picture (shown in Finder)"
    note "  on your phone: https://raw.githubusercontent.com/NousResearch/hermes-agent/$rev/apps/desktop/assets/icon.png"
    /usr/bin/open -R "$picture" 2>/dev/null || true
    gum confirm --affirmative "Check again" --negative "Skip" "Done?" || return
  done
}

secrets="$(setting server.hermes.secretsFile)"
if sudo test -e "$secrets"; then
  ok "Secrets in $secrets"
  bot_token="$(sudo sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$secrets")"
else
  step "Your Telegram bot"
  note "Its token and your Telegram id go to $secrets, readable by Hermes only."
  bot_token="$(new_bot_token)"
  bot="$(tg "$bot_token" getMe | "$JQ" -r .result.username)"
  owner="$(owner_id "$bot_token" "$bot")"
  sudo mkdir -p "$(dirname "$secrets")"
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\n' \
    "$bot_token" "${owner//[^0-9]/}" | write_secret "$secrets"
  ok "Secrets written"
  # What people see before their first message; BotFather's /setdescription does the same.
  tg "$bot_token" setMyShortDescription "short_description=Hermes%2C%20a%20personal%20agent%20on%20a%20home%20server" >/dev/null || true
  tg "$bot_token" setMyDescription "description=Hermes%20answers%20only%20its%20owner." >/dev/null || true
fi
# Topics: your DM's root is the main chat, and its topics are sub-chats only
# the bot opens (/sub new), so a message sent outside a topic stays in the main
# chat. That takes BotFather's Threaded Mode, with users kept from creating
# topics themselves.
topics() {
  local token="$1" owner="$2" bot probe thread
  bot="$(tg "$token" getMe | "$JQ" -r .result.username)"
  step "Topics, for sub-chats in your chat with @$bot (optional)"
  note "In @BotFather, tap Open (its Mini App): My bots → @$bot → Bot Settings → Threads Settings:"
  note "\"Threaded Mode\" ON, \"Disallow users to create new threads\" ON."
  note "Without topics, groups with @$bot are the sub-chats."
  # getMe's topic fields are not a test on their own: Telegram updates them
  # once topics are used, not when BotFather's switches change. Creating a
  # topic is, and getMe is right after it.
  while gum confirm --affirmative "Check" --negative "No topics" "Both switches on?"; do
    if probe="$(curl -sS "https://api.telegram.org/bot$token/createForumTopic" \
      --data-urlencode "chat_id=$owner" --data-urlencode "name=Setup check")" \
      && [ "$("$JQ" -r .ok <<< "$probe")" = true ]; then
      thread="$("$JQ" -r .result.message_thread_id <<< "$probe")"
      tg_post "$token" deleteForumTopic "chat_id=$owner" "message_thread_id=$thread" >/dev/null || true
      if [ "$(tg "$token" getMe | "$JQ" -r .result.allows_users_to_create_topics)" = false ]; then
        ok "Topics are on: send /sub new in your chat with @$bot to open a sub-chat"
        return 0
      fi
      warn "Threaded Mode is on, but you can still create topics: switch \"Disallow users to create new threads\" on."
      continue
    fi
    if grep -q "not a forum" <<< "$probe"; then
      # Your DM turns into a forum only with a message sent after Threaded Mode is on.
      warn "Send @$bot any message, then check again (or turn Threaded Mode on first)."
      continue
    fi
    warn "Telegram refused a topic: $("$JQ" -r '.description // empty' <<< "$probe" 2>/dev/null || printf '%s' "$probe")"
  done
}

if [ -n "${bot_token:-}" ]; then
  botfather_settings "$bot_token" "$(tg "$bot_token" getMe | "$JQ" -r .result.username)"
  topics "$bot_token" "${owner:-$(sudo sed -n 's/^TELEGRAM_ALLOWED_USERS=//p' "$secrets" | cut -d, -f1)}"
fi
