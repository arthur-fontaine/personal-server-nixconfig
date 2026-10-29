#!/usr/bin/env bash
# Sets the server up from a fresh Mac, including everything Nix cannot do:
# SSH keys, secrets, the Telegram bot, the Hermes account's login, GitHub
# access and the macOS permissions. Run it once, at the Mac's own screen (the
# permission dialogs show there), and let it reboot: nothing is left to run
# afterwards. Each step checks whether it is done first, so running it again
# from the clone (~/personal-server-nixconfig/scripts/bootstrap-macos.sh)
# only redoes what is missing, e.g. BotFather settings left for later.
#
# Modelled on https://github.com/arthur-fontaine/nixconfig/blob/main/scripts/bootstrap-macos.sh,
# with gum (https://github.com/charmbracelet/gum) for the prompts and no Homebrew.
set -euo pipefail

REPO_URL="${NIXCONFIG_REPO_URL:-https://github.com/arthur-fontaine/personal-server-nixconfig.git}"
REPO_DIR="${NIXCONFIG_REPO_DIR:-$HOME/personal-server-nixconfig}"
NIX_INSTALLER_URL="https://nixos.org/nix/install"
DEFAULT_HOST="Personal-Server"

[ "$(uname -s)" = Darwin ] || { echo "This script only supports macOS." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "This server configuration targets Apple Silicon." >&2; exit 1; }
[ -t 0 ] || { echo "Run this from an interactive terminal." >&2; exit 1; }

echo "Administrator access is needed for Nix, the system and the Hermes account."
sudo -v
while sudo -n true 2>/dev/null; do sleep 60; done &
trap 'kill $! >/dev/null 2>&1 || true' EXIT

# ── Nix, then gum from it ───────────────────────────────────────────────────

if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  echo "Installing Nix (multi-user)..."
  sh <(curl --proto '=https' --tlsv1.2 -fsSL "$NIX_INSTALLER_URL") --daemon --yes
fi
export PATH="/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
nix() { command nix --extra-experimental-features 'nix-command flakes' "$@"; }

GUM="$(nix build --no-link --print-out-paths nixpkgs#gum)/bin/gum"
gum() { "$GUM" "$@"; }
step() { gum style --bold --foreground 212 "▶ $1"; }
ok() { gum style --foreground 42 "✓ $1"; }
note() { gum style --faint "  $1"; }
warn() { gum style --foreground 214 "! $1"; }

gum style --border rounded --padding "0 2" --bold "personal-server-nixconfig setup" \
  "$(gum style --faint 'Nix, nix-darwin and a Hermes Agent on this Mac')"

# ── The repository and this host ────────────────────────────────────────────

if [ ! -d "$REPO_DIR/.git" ]; then
  step "Cloning $REPO_URL"
  nix run nixpkgs#git -- clone "$REPO_URL" "$REPO_DIR"
fi
ok "Repository at $REPO_DIR"

# A Nix string literal for a shell value.
nix_string() {
  local s="$1" bs='\' q='"' interp='${'
  s="${s//"$bs"/"$bs$bs"}"
  s="${s//"$q"/"$bs$q"}"
  s="${s//"$interp"/"$bs$interp"}"
  printf '"%s"' "$s"
}

ssh_keys() {
  local source keys="" user
  source="$(gum choose --header "Which public keys may log in over SSH?" \
    "My GitHub account's keys" "Paste them" "This Mac's ~/.ssh/*.pub")"
  case "$source" in
    "My GitHub account's keys")
      user="$(gum input --header "GitHub user name" --placeholder "arthur-fontaine")"
      keys="$(curl -fsSL "https://github.com/$user.keys")"
      ;;
    "Paste them")
      keys="$(gum write --header "One public key per line" --placeholder "ssh-ed25519 AAAA... laptop")"
      ;;
    *)
      keys="$(cat "$HOME"/.ssh/*.pub 2>/dev/null || true)"
      ;;
  esac
  printf '%s\n' "$keys" | grep -E '^(ssh-|ecdsa-|sk-)' || true
}

local_nix="$REPO_DIR/hosts/local.nix"
if [ -e "$local_nix" ]; then
  HOST="$(sed -n 's/^  \([A-Za-z0-9_-]*\) = {$/\1/p' "$local_nix" | head -1)"
  ok "Host $HOST (hosts/local.nix)"
else
  step "This host"
  HOST="$(gum input --header "Host name" --value "$DEFAULT_HOST")"
  keys="$(ssh_keys)"
  if [ -z "$keys" ]; then
    warn "No SSH key: nobody will be able to log in remotely. Add one to $local_nix later."
  else
    note "$(printf '%s\n' "$keys" | wc -l | tr -d ' ') key(s) will be allowed."
  fi
  {
    echo "# This Mac's host, written by scripts/bootstrap-macos.sh. Git-ignored."
    echo "{"
    echo "  $HOST = {"
    echo "    system = \"aarch64-darwin\";"
    echo "    username = $(nix_string "$(id -un)");"
    echo "    nixconfigDir = $(nix_string "$REPO_DIR");"
    echo "    server.ssh.authorizedKeys = ["
    while IFS= read -r key; do
      [ -n "$key" ] && echo "      $(nix_string "$key")"
    done <<< "$keys"
    echo "    ];"
    echo "  };"
    echo "}"
  } > "$local_nix"
  ok "Wrote hosts/local.nix"
fi

flake="path:$REPO_DIR#darwinConfigurations.$HOST"
setting() { nix eval --raw "$flake.config.$1" --apply toString; }

# Write stdin to a root-owned file that is never readable by anyone else, even briefly.
write_secret() { sudo sh -c 'umask 077 && cat > "$1"' _ "$1"; }

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
  step "Secrets (stored in $secrets, readable by Hermes only)"
  runpod="$(gum input --password --header "RunPod API key (https://www.runpod.io/console/user/settings)")"
  step "Your Telegram bot"
  bot_token="$(new_bot_token)"
  bot="$(tg "$bot_token" getMe | "$JQ" -r .result.username)"
  owner="$(owner_id "$bot_token" "$bot")"
  sudo mkdir -p "$(dirname "$secrets")"
  printf 'RUNPOD_API_KEY=%s\nTELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\n' \
    "$runpod" "$bot_token" "${owner//[^0-9]/}" | write_secret "$secrets"
  unset runpod
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

# ── Models: the main one, then its fallbacks ────────────────────────────────
# Hermes tries them in order when one fails (a limit reached, an outage), for
# that turn; the local model (uzu) always comes last. Written to
# hosts/local.nix (server.hermes.model, server.hermes.fallbacks).

# label|provider|model
model_choices=(
  "ChatGPT subscription: gpt-6-sol|openai-codex|gpt-6-sol"
  "ChatGPT subscription: gpt-5.5|openai-codex|gpt-5.5"
  "OpenCode Zen: DeepSeek V4.1 Flash (pay as you go)|opencode-zen|deepseek-v4.1-flash"
  "Another provider and model…|other|"
)
model_entry() { # a label → {"provider", "name"}
  local line provider name
  for line in "${model_choices[@]}"; do
    [ "${line%%|*}" = "$1" ] || continue
    provider="$(cut -d'|' -f2 <<< "$line")"
    name="$(cut -d'|' -f3 <<< "$line")"
    if [ "$provider" = other ]; then
      provider="$(gum input --header "Provider (a Hermes provider id: openrouter, anthropic, deepseek…)")"
      name="$(gum input --header "Model for $provider")"
    fi
    "$JQ" -cn --arg p "$provider" --arg n "$name" '{provider: $p, name: $n}'
  done
}
model_chain() {
  nix eval --json "$flake.config.server.hermes" --apply 'h: [h.model] ++ map (f: { provider = f.provider; name = f.model; }) h.fallbacks' \
    | "$JQ" -r 'map("\(.name) (\(.provider))") | join(" → ")'
}

if grep -q 'fallbacks' "$local_nix" 2>/dev/null && ! gum confirm --default=false "Models: $(model_chain) → the local model. Change them?"; then
  ok "Models: $(model_chain) → the local model"
else
  step "Models"
  note "The main model, then the ones Hermes falls back to, in order, when one fails;"
  note "the local model (uzu) always comes last. A ChatGPT subscription logs in after the install."
  labels=()
  for line in "${model_choices[@]}"; do labels+=("${line%%|*}"); done
  main="$(model_entry "$(gum choose --header "Main model" "${labels[@]}")")"
  fallbacks="[]"
  while :; do
    pick="$(gum choose --header "Then, when it fails" "${labels[@]}" "Nothing else: then the local model")"
    [ "$pick" = "Nothing else: then the local model" ] && break
    fallbacks="$("$JQ" -c --argjson f "$(model_entry "$pick")" '. + [{provider: $f.provider, model: $f.name}]' <<< "$fallbacks")"
  done
  text="$(REPO="$REPO_DIR" HOST="$HOST" \
    PATCH="$("$JQ" -cn --argjson m "$main" --argjson f "$fallbacks" '{server: {hermes: {model: $m, fallbacks: $f}}}')" \
    nix eval --impure --raw --file "$REPO_DIR/scripts/lib/set-host.nix")"
  printf '%s' "$text" > "$local_nix"
  ok "Models: $(model_chain) → the local model"
fi

# The API key of each provider in the chain, asked only for those it uses and
# not yet in the secrets file. ChatGPT logs in instead (below), uzu needs none.
provider_key() { # provider → "VARIABLE|where to get one"
  case "$1" in
    openai-codex | uzu) ;;
    opencode-zen) echo "OPENCODE_ZEN_API_KEY|https://opencode.ai/auth" ;;
    opencode-go) echo "OPENCODE_GO_API_KEY|https://opencode.ai/auth" ;;
    openrouter) echo "OPENROUTER_API_KEY|https://openrouter.ai/settings/keys" ;;
    anthropic) echo "ANTHROPIC_API_KEY|https://console.anthropic.com/settings/keys" ;;
    deepseek) echo "DEEPSEEK_API_KEY|https://platform.deepseek.com/api_keys" ;;
    gemini) echo "GOOGLE_API_KEY|https://aistudio.google.com/apikey" ;;
    xai) echo "XAI_API_KEY|https://console.x.ai" ;;
    *)
      # Hermes' docs list each provider's variable (docs/user-guide/features/fallback-providers.md).
      gum input --header "The environment variable holding $1's API key (empty if it needs none)" ;;
  esac
}
for provider in $(nix eval --json "$flake.config.server.hermes" \
  --apply 'h: [h.model.provider] ++ map (f: f.provider) h.fallbacks' | "$JQ" -r 'unique[]'); do
  key="$(provider_key "$provider")"
  var="${key%%|*}"
  [ -n "$var" ] || continue
  if sudo grep -q "^$var=." "$secrets"; then
    ok "$provider: its key is in the secrets file"
    continue
  fi
  url="${key#*|}"
  [ "$url" = "$key" ] && url=""
  value="$(gum input --password --header "$provider API key ($var${url:+, from $url}; empty to skip)" | tr -d '[:space:]')"
  if [ -n "$value" ]; then
    # Read first, then rewrite in place (same owner and mode): a key left
    # empty by an earlier run gives way to this one.
    others="$(sudo grep -v "^$var=" "$secrets" || true)"
    printf '%s\n%s=%s\n' "$others" "$var" "$value" | sed '/^$/d' | write_secret "$secrets"
    unset others
    ok "$provider: key written"
  else
    warn "$provider has no key: Hermes skips it in the chain."
  fi
  unset value
done

# ── The system ──────────────────────────────────────────────────────────────

switch_system() {
  if [ -x /run/current-system/sw/bin/darwin-rebuild ]; then
    sudo -H env PATH="$PATH" darwin-rebuild switch --flake "path:$REPO_DIR#$HOST"
  else
    sudo -H env PATH="$PATH" nix --extra-experimental-features 'nix-command flakes' \
      run github:LnL7/nix-darwin#darwin-rebuild -- switch --flake "path:$REPO_DIR#$HOST"
  fi
}

# nix-darwin will not overwrite an /etc file it does not recognise (often
# /etc/shells on a first switch): it lists them and asks to rename them
# <file>.before-nix-darwin. Do that, with your go-ahead, and switch again.
apply() {
  local log files
  log="$(mktemp)"
  if switch_system 2>&1 | tee "$log"; then
    rm -f "$log"
    return 0
  fi
  files="$(sed -n '/would be overwritten:/,/^Please check/p' "$log" | sed -n 's|^[[:space:]]*\(/etc/[^[:space:]]*\)$|\1|p')"
  rm -f "$log"
  [ -n "$files" ] || return 1
  warn "nix-darwin wants to manage these files, which macOS or an installer already wrote:"
  printf '  %s\n' $files
  gum confirm "Rename them to <file>.before-nix-darwin and apply again?" || return 1
  for file in $files; do
    sudo mv "$file" "$file.before-nix-darwin"
  done
  switch_system
}

agent="$(setting server.hermes.user)"
if ! id "$agent" >/dev/null 2>&1 || gum confirm --default=false "Apply the configuration again?"; then
  step "Applying the configuration (nix-darwin)"
  apply
  ok "Configuration applied"
fi
agent_uid="$(id -u "$agent")"
as_agent() { sudo -u "$agent" -H env PATH="/etc/profiles/per-user/$agent/bin:$PATH" "$@"; }
gui_session() { sudo launchctl print "gui/$agent_uid" >/dev/null 2>&1; }

# ── The Hermes account logs in at boot ──────────────────────────────────────

if sudo test -e /etc/kcpassword; then
  ok "$agent logs in automatically"
else
  step "Automatic login for $agent"
  if fdesetup isactive >/dev/null 2>&1; then
    warn "FileVault is on, and macOS logs nobody in automatically while it is."
    if gum confirm "Turn FileVault off? (macOS asks for your password, the one that unlocks the disk)"; then
      # FileVault releases the disk's key only for a user allowed to unlock it,
      # whatever sudo says: the password cannot be skipped, the user name can.
      sudo fdesetup disable -user "$(id -un)"
    fi
  fi
  if fdesetup isactive >/dev/null 2>&1; then
    warn "Skipped: computer use and uzu need $agent logged in. Run this script again once FileVault is off."
  else
    # A random password: nobody types it, macOS replays it at boot from
    # /etc/kcpassword (the password XORed with Apple's fixed key, padded to 12 bytes).
    password="$(openssl rand -base64 24)"
    sudo dscl . -passwd "/Users/$agent" "$password"
    /usr/bin/perl -e '
      my @key = (0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F);
      my $p = shift; $p .= "\0" x (12 - length($p) % 12);
      print join "", map { chr(ord(substr($p, $_, 1)) ^ $key[$_ % 11]) } 0 .. length($p) - 1;
    ' "$password" | write_secret /etc/kcpassword
    unset password
    ok "$agent will log in at boot"
  fi
fi

# ── GitHub, so Hermes can push changes to this repository ──────────────────
# Both tokens from pre-filled pages: a fine-grained template URL (documented in
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
# and the classic form's scopes parameter.

# owner/repo of the remote, https or ssh.
repo_slug="$(setting server.nixconfig.remote | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"

# Opened in a browser when this session has a screen, always printed.
show_link() {
  note "$1"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 && /usr/bin/open "$1" 2>/dev/null || true
}

if as_agent gh auth status >/dev/null 2>&1; then
  ok "Hermes can push to GitHub"
else
  step "GitHub access for Hermes"
  note "A fine-grained token with Contents: read and write, pre-filled on this page:"
  show_link "https://github.com/settings/personal-access-tokens/new?name=Hermes%20(personal%20server)&description=Hermes%20pushes%20changes%20to%20${repo_slug//\//%2F}%20and%20applies%20them&target_name=${repo_slug%%/*}&expires_in=366&contents=write"
  note "Under Repository access, choose Only select repositories → ${repo_slug#*/} (a link cannot pick it)."
  note "Whoever can push here can change the whole Mac through sudo server-rebuild. It lasts a year:"
  note "run this script again to replace it."
  token="$(gum input --password --header "GitHub token (github_pat_…, empty to skip)")"
  if [ -n "$token" ]; then
    # In gh's own file (~/.config/gh/hosts.yml, readable by the agent only), not
    # the keychain: the agent's runs unattended, and from here it has none.
    printf '%s' "$token" | as_agent gh auth login --git-protocol https --insecure-storage --with-token
    unset token
    ok "Hermes can push to GitHub"
  else
    warn "Skipped: Hermes cannot push configuration changes yet."
  fi
fi

# Notifications, for Hermes' events (docs/events.md): fine-grained tokens
# cannot read them, so a classic token with that one scope, kept apart.
if sudo grep -q '^GITHUB_NOTIFICATIONS_TOKEN=' "$secrets"; then
  ok "Hermes reads your GitHub notifications"
elif [ "$(setting server.hermes.events.github)" = 1 ]; then
  step "GitHub notifications, as Hermes' events (optional)"
  note "A classic token with only the notifications scope, pre-filled on this page:"
  show_link "https://github.com/settings/tokens/new?description=Hermes%20notifications%20(personal%20server)&scopes=notifications"
  token="$(gum input --password --header "Notifications token (ghp_…, empty to skip)")"
  if [ -n "$token" ]; then
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" https://api.github.com/notifications)" = 200 ]; then
      printf 'GITHUB_NOTIFICATIONS_TOKEN=%s\n' "$token" | sudo sh -c 'umask 077 && cat >> "$1"' _ "$secrets"
      ok "Hermes reads your GitHub notifications"
    else
      warn "GitHub refused that token for notifications: skipped. Run this script again to retry."
    fi
    unset token
  fi
fi

# ── Your ChatGPT subscription, when the chain uses it ──────────────────────

uses_codex="$(nix eval --json "$flake.config.server.hermes" --apply 'h: builtins.any (p: p == "openai-codex") ([h.model.provider] ++ map (f: f.provider) h.fallbacks)')"
if [ "$uses_codex" = true ]; then
  hermes_cli() {
    as_agent env HERMES_HOME="$(setting server.hermes.home)/.hermes" \
      "$(setting "home-manager.users.$agent.services.hermes-agent.package")/bin/hermes" "$@"
  }
  if ! hermes_cli auth status openai-codex 2>&1 | grep -q "logged out"; then
    ok "Hermes is logged in to your ChatGPT subscription"
  else
    step "Your ChatGPT subscription"
    note "Hermes logs in with a code: open the link it shows (on any device), sign in to ChatGPT, enter the code."
    if hermes_cli auth add openai-codex --type oauth; then
      ok "Hermes is logged in to your ChatGPT subscription"
    else
      warn "Not logged in: Hermes falls back to the next model. Run this script again to retry."
    fi
  fi
fi

# ── Events: the daemon and Hermes' webhook route share one secret ──────────

if ! sudo grep -q '^WEBHOOK_SECRET=' "$secrets"; then
  printf 'WEBHOOK_SECRET=%s\n' "$(openssl rand -hex 32)" | sudo sh -c 'umask 077 && cat >> "$1"' _ "$secrets"
  ok "Secret for Hermes' events written"
fi

# ── 1Password, for the logins Hermes may use ───────────────────────────────
# A service account that reads one vault: browser_vault fills its logins into
# web pages (Instagram) without the model seeing them.

op_vault="$(setting server.hermes.onepassword.vault)"
if sudo grep -q '^OP_SERVICE_ACCOUNT_TOKEN=' "$secrets"; then
  ok "Hermes reads 1Password's \"$op_vault\" vault"
else
  step "1Password for Hermes (optional)"
  note "In 1Password: create a vault named \"$op_vault\", then Developer → Service Accounts → New,"
  note "with read access to \"$op_vault\" only. Put there the logins Hermes may use."
  op_token="$(gum input --password --header "Service account token (ops_…, empty to skip)")"
  if [ -n "$op_token" ]; then
    op="$(nix build --no-link --print-out-paths "$flake.pkgs._1password-cli")/bin/op"
    if OP_SERVICE_ACCOUNT_TOKEN="$op_token" "$op" vault list --format json 2>/dev/null \
      | "$JQ" -e --arg v "$op_vault" 'any(.[]; .name == $v)' >/dev/null; then
      printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$op_token" | sudo sh -c 'umask 077 && cat >> "$1"' _ "$secrets"
      ok "Hermes reads 1Password's \"$op_vault\" vault"
    else
      warn "That token cannot read a vault named \"$op_vault\": skipped. Run this script again to retry."
    fi
    unset op_token
  fi
fi

# ── WhatsApp, as a linked device of your number ────────────────────────────

wa() { as_agent env WACLI_STORE_DIR="$(setting "home-manager.users.$agent.services.hermes-agent.environment.WACLI_STORE_DIR")" wacli "$@"; }
if wa --json auth status 2>/dev/null | grep -q '"authenticated":true'; then
  ok "Hermes reads your WhatsApp"
elif gum confirm "Link your WhatsApp, so Hermes can read and send your messages?"; then
  step "WhatsApp"
  note "On your phone: WhatsApp → Settings → Linked devices → Link a device, then scan this code."
  if wa auth --idle-exit 30s; then
    ok "WhatsApp linked: its chats keep syncing in the background"
    gui_session && sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.wacli" || true
  else
    warn "Not linked. Run this script again to retry."
  fi
fi

# ── Permissions ─────────────────────────────────────────────────────────────
# Accessibility, Screen Recording and Full Disk Access live in macOS' system
# database, so granting them from this session covers the Hermes account too.
# The dialogs need a screen: this session's if it has one, else Hermes'.

cua="$(setting home-manager.users.$agent.services.hermes-agent.environment.HERMES_CUA_DRIVER_CMD)"
launcher="$(setting server.hermes.access.launcher)"
if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  in_gui() { env CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$@"; }
  lit() { :; }
elif gui_session; then
  in_gui() { sudo launchctl asuser "$agent_uid" sudo -u "$agent" -H env CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$@"; }
  # Hermes' session keeps the backlight off: light it while you click.
  brightness="$(nix build --no-link --print-out-paths "path:$REPO_DIR#display-brightness")/bin/display-brightness"
  lit() { in_gui "$brightness" "$1" || true; }
else
  in_gui() { return 1; }
  lit() { :; }
fi

if in_gui true; then
  # "unknown" until the driver's daemon has run once.
  permissions="$(in_gui "$cua" permissions status --json 2>/dev/null | sed -n 's/.*"status": *"\([a-z_]*\)".*/\1/p')"
  if [ "$permissions" != granted ] && gum confirm "Grant computer use its permissions now? (status: ${permissions:-unknown})"; then
    step "Accessibility and Screen Recording for CuaDriver"
    note "Dialogs open on this Mac's screen: click Allow / Open System Settings,"
    note "turn CuaDriver on in each list, then come back here."
    lit 1
    in_gui "$cua" permissions grant || true
    gum confirm --affirmative "Done" --negative "" "Granted both?" || true
    lit "$(setting server.energy.displayBrightness)"
  fi

  if gum confirm "Give Hermes Full Disk Access? (to read Desktop, Documents, Downloads, Mail, iCloud...)"; then
    step "Full Disk Access for $launcher"
    note "In the list that opens, click +, then drag in the file Finder shows (or ⇧⌘G and paste its path)."
    note "It is granted once: Hermes updates keep it."
    lit 1
    in_gui /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    in_gui /usr/bin/open -R "$launcher"
    gum confirm --affirmative "Done" --negative "" "Added?" || true
    lit "$(setting server.energy.displayBrightness)"
  fi
  ok "Permissions handled"
else
  warn "No screen here (SSH?): run this script at the Mac itself to grant the permissions."
fi

# ── Apple apps ──────────────────────────────────────────────────────────────
# Messages, Notes, Reminders, Contacts, Calendar and Find My act on the Apple
# Account the Hermes account is signed in to, and each asks macOS (TCC) the
# first time it is used. A permission belongs to the process that asked: here,
# as for the gateway, the launcher that launchd starts in Hermes' session, so
# the dialogs show on Hermes' desktop and what you allow is the gateway's.

gateway_path="$(setting "home-manager.users.$agent.launchd.agents.hermes-agent.config.EnvironmentVariables.PATH")"
# Hermes' desktop, even when yours is open too.
hermes_gui() { sudo launchctl asuser "$agent_uid" sudo -u "$agent" -H "$@"; }
hermes_lit() {
  hermes_gui "$(nix build --no-link --print-out-paths "path:$REPO_DIR#display-brightness")/bin/display-brightness" "$1" || true
}

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"; }

# Runs a shell command the way the gateway runs; prints its output, returns its
# status. It waits up to 5 minutes, for a dialog to be answered.
as_gateway() {
  local cmd="$1" label=org.personal-server.bootstrap-check dir code=""
  dir="$(sudo -u "$agent" mktemp -d /tmp/hermes-check.XXXXXX)"
  sudo -u "$agent" tee "$dir/job.plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$(xml "$launcher")</string><string>/bin/sh</string><string>-c</string><string>$(xml "$cmd")</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml "$gateway_path")</string></dict>
  <key>StandardOutPath</key><string>$dir/out</string>
  <key>StandardErrorPath</key><string>$dir/out</string>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
  sudo launchctl bootout "gui/$agent_uid/$label" 2>/dev/null || true
  if sudo launchctl bootstrap "gui/$agent_uid" "$dir/job.plist"; then
    for _ in $(seq 300); do
      sleep 1
      code="$(sudo launchctl print "gui/$agent_uid/$label" 2>/dev/null \
        | sed -n 's/^[[:space:]]*last exit code = \([0-9][0-9]*\).*/\1/p')"
      [ -n "$code" ] && break
    done
    sudo launchctl bootout "gui/$agent_uid/$label" 2>/dev/null || true
  fi
  sudo cat "$dir/out" 2>/dev/null || true
  sudo rm -rf "$dir"
  return "${code:-1}"
}

apple_account() {
  as_agent /usr/bin/defaults read MobileMeAccounts Accounts 2>/dev/null | grep -q AccountID
}

# One app: run its check, which also brings up its dialog, until it passes.
apple_app() {
  local what="$1" check="$2" out
  while :; do
    if out="$(as_gateway "$check" 2>&1)"; then
      ok "$what"
      return 0
    fi
    warn "$what: not allowed yet${out:+ ($(head -c 200 <<< "$out"))}"
    note "Click Allow on the Mac's screen, or turn it on in System Settings → Privacy & Security."
    gum confirm --affirmative "Check again" --negative "Skip" "Allowed?" || return 0
  done
}

apple_apps() {
  step "Hermes' Apple Account"
  while ! apple_account; do
    note "On the Mac's screen, in the System Settings that opens, sign in with your Apple Account,"
    note "then in iCloud turn on Messages, Notes, Reminders, Contacts, Calendars and Find My Mac."
    hermes_gui /usr/bin/open "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings" || true
    gum confirm --affirmative "Check again" --negative "Skip" "Signed in?" || return 0
  done
  ok "$agent is signed in to an Apple Account"

  step "Each Apple app's permission (dialogs on the Mac's screen)"
  apple_app "Reminders" 'remindctl authorize >/dev/null 2>&1; [ "$(remindctl status --plain)" = full-access ]'
  apple_app "Notes" "osascript -e 'tell application \"Notes\" to count notes'"
  apple_app "Contacts" "osascript -e 'tell application \"Contacts\" to count people'"
  apple_app "Calendar" "osascript -e 'tell application \"Calendar\" to count calendars'"
  apple_app "Messages (sending)" "osascript -e 'tell application \"Messages\" to count accounts'"

  # Reading needs Full Disk Access (Permissions, above) and Messages in iCloud,
  # which Messages turns on itself, not iCloud's settings.
  while ! as_gateway 'imsg chats --limit 1 | grep -q .' >/dev/null 2>&1; do
    warn "Hermes cannot read your messages yet."
    note "In Messages, which opens on the Mac's screen: sign in if it asks, then"
    note "Messages → Settings → iMessage → \"Enable Messages in iCloud\", and wait for it to sync."
    note "Still empty after that? Give $launcher Full Disk Access (run this script again at the Mac)."
    hermes_gui /usr/bin/open -a Messages || true
    gum confirm --affirmative "Check again" --negative "Skip" "Done?" || break
  done
  as_gateway 'imsg chats --limit 1 | grep -q .' >/dev/null 2>&1 && ok "Messages (reading)"

  # Find My has no API: Hermes reads FindMy.app's window, which takes
  # Screen Recording and Accessibility for the launcher, added by hand.
  if as_gateway 'peekaboo permissions --json --no-remote | jq -e "[.data.permissions[] | select(.isRequired) | .isGranted] | all"' >/dev/null 2>&1; then
    ok "Find My (screen reading)"
  elif gum confirm "Let Hermes read app windows (Find My, through peekaboo)?"; then
    note "In each list that opens, click +, then drag in the file Finder shows (or ⇧⌘G and paste its path)."
    hermes_gui /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture" || true
    hermes_gui /usr/bin/open -R "$launcher" || true
    gum confirm --affirmative "Next" --negative "" "Screen Recording added?" || true
    hermes_gui /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility" || true
    gum confirm --affirmative "Done" --negative "" "Accessibility added?" || true
  fi

  imcp_apps
  homeclaw_app
}

agent_home="$(setting server.hermes.home)"
imcp_prefs="$agent_home/Library/Containers/co.dododo.iMCP/Data/Library/Preferences/co.dododo.iMCP"
# What iMCP serves Hermes (modules/hermes/agent/apple.nix); Maps uses Location.
imcp_services=(calendar contacts location mail music shortcuts voiceMemos weather)

imcp_apps() {
  local service missing init
  step "iMCP: Calendar, Contacts, Mail, Maps, Music, Shortcuts, Voice Memos, Weather"
  sudo launchctl kickstart "gui/$agent_uid/org.nix-community.home.imcp" 2>/dev/null || true
  sleep 3
  # Its settings live in its container, which its first launch created.
  as_agent hermes-app-defaults
  while :; do
    missing=()
    for service in "${imcp_services[@]}"; do
      [ "$(as_agent /usr/bin/defaults read "$imcp_prefs" "${service}Enabled" 2>/dev/null)" = 1 ] || missing+=("$service")
    done
    if [ "${#missing[@]}" = 0 ]; then
      ok "iMCP serves all of them"
      break
    fi
    note "On the Mac's screen, click iMCP's icon in the menu bar, then each gray service: ${missing[*]}."
    note "Allow each dialog. Mail asks for a folder: choose ~/Library/Mail; Voice Memos, its recordings."
    note "Leave Reminders, Notes and Messages off: Hermes' skills do those."
    gum confirm --affirmative "Check again" --negative "Skip" "Turned on?" || break
  done
  # imcp-server finds the app over Bonjour, which macOS asks about (Local Network).
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hermes-agent","version":"0"}}}'
  apple_app "iMCP reachable from Hermes (Local Network)" \
    "(printf '%s\n' '$init'; sleep 15) | timeout 20 /Applications/iMCP.app/Contents/MacOS/imcp-server | grep -m1 -q serverInfo"
}

# HomeClaw is on the App Store only: Apple allows HomeKit nowhere else.
homeclaw_app() {
  local mas
  step "HomeClaw: HomeKit"
  if [ ! -d /Applications/HomeClaw.app ]; then
    mas="$(nix build --no-link --print-out-paths "$flake.pkgs.mas")/bin/mas"
    # mas installs as root for the App Store account of SUDO_UID: Hermes'.
    if ! sudo launchctl asuser "$agent_uid" env SUDO_UID="$agent_uid" SUDO_GID="$(id -g "$agent")" \
      SUDO_USER="$agent" HOME="$agent_home" "$mas" get 6759682551; then
      note "On the Mac's screen, install HomeClaw from the App Store that opens (Get)."
      hermes_gui /usr/bin/open "macappstore://apps.apple.com/app/id6759682551" || true
      gum confirm --affirmative "Done" --negative "Skip" "Installed?" || return 0
    fi
  fi
  [ -d /Applications/HomeClaw.app ] || { warn "HomeClaw is not installed: skipped."; return 0; }
  note "On the Mac's screen, allow HomeClaw to access your home data."
  sudo launchctl kickstart "gui/$agent_uid/org.nix-community.home.homeclaw" 2>/dev/null || true
  sleep 5
  # Its HTTP MCP switch, read at launch: set, then restart it.
  as_agent hermes-app-defaults
  sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.homeclaw" 2>/dev/null || true
  while [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/mcp)" = 000 ]; do
    warn "HomeClaw's MCP endpoint does not answer yet."
    note "In HomeClaw's menu bar icon → Settings → Integrations, turn on Streamable HTTP MCP."
    gum confirm --affirmative "Check again" --negative "Skip" "On?" || return 0
  done
  ok "HomeClaw serves HomeKit to Hermes"

  # Its events go to Hermes' events daemon (docs/events.md), with the secret
  # the daemon checks as a Bearer token.
  local cli=/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli token
  token="$(sudo sed -n 's/^WEBHOOK_SECRET=//p' "$secrets")"
  if hermes_gui "$cli" config --webhook-url "http://127.0.0.1:$(setting server.hermes.events.port)" \
    --webhook-token "$token" --webhook-enabled true >/dev/null && hermes_gui "$cli" config --webhook-test >/dev/null; then
    ok "HomeClaw reports to Hermes' events"
    note "Choose what it reports: HomeClaw's menu bar icon → Settings → Webhook, turn on the doors, sensors…"
    note "(Immediate for what matters now, Batched for the rest)."
  else
    warn "Could not point HomeClaw's webhook at Hermes: Settings → Webhook, URL http://127.0.0.1:$(setting server.hermes.events.port)"
  fi
  unset token
}

# ── Instagram, in Hermes' browser ───────────────────────────────────────────
# Its first login is yours, on the Mac's screen, in Hermes' always-open Chrome
# (modules/hermes/agent/browser.nix): Instagram trusts a login made by hand,
# and later ones come from 1Password.

browser_profile="$agent_home/.hermes/browser-profile"
instagram_logged_in() {
  sudo -u "$agent" /usr/bin/sqlite3 "file:$browser_profile/Default/Cookies?mode=ro&immutable=1" \
    "select count(*) from cookies where host_key like '%instagram.com' and name = 'sessionid';" 2>/dev/null \
    | grep -qx '[1-9][0-9]*'
}

instagram_login() {
  step "Instagram"
  # Hermes' always-open Chrome (modules/hermes/agent/browser.nix) opens on it.
  sudo launchctl kickstart "gui/$agent_uid/org.nix-community.home.chrome" 2>/dev/null || true
  while ! instagram_logged_in; do
    note "On the Mac's screen, in the Chrome window on instagram.com: log in, and save the login info."
    note "If Instagram offers notifications, turn them on: they become Hermes' events."
    note "Chrome writes its cookies within half a minute."
    gum confirm --affirmative "Check" --negative "Skip" "Logged in?" || return 0
  done
  ok "Hermes is logged in to Instagram"
}

# Discord keeps its session in the site's storage, not a cookie this script
# can read, so your "logged in" is what is recorded.
discord_marker="$agent_home/.local/state/hermes-events/discord-logged-in"
discord_login() {
  step "Discord"
  note "On the Mac's screen, in Chrome, the Discord tab (Hermes' events keep it open): log in."
  note "Scanning the QR code with Discord's phone app is easiest. Allow notifications if it asks."
  if gum confirm --affirmative "Logged in" --negative "Skip" "Logged in to Discord?"; then
    as_agent sh -c 'mkdir -p "$(dirname "$1")" && touch "$1"' _ "$discord_marker"
    ok "Hermes is logged in to Discord"
  fi
}

if gui_session && [ "$(stat -f %Su /dev/console)" = "$agent" ]; then
  if gum confirm "Set up Hermes' Apple apps (iMessage, Notes, Reminders, Contacts, Calendar, Find My)?"; then
    hermes_lit 1
    apple_apps
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
  if instagram_logged_in; then
    ok "Hermes is logged in to Instagram"
  elif gum confirm "Log Hermes in to your Instagram?"; then
    hermes_lit 1
    instagram_login
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
  if sudo test -e "$discord_marker"; then
    ok "Hermes was logged in to Discord (it logs in again from 1Password when needed)"
  elif gum confirm "Log Hermes in to your Discord?"; then
    hermes_lit 1
    discord_login
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
else
  warn "Hermes' Apple apps, Instagram and Discord need its desktop on the Mac's screen, which it is after a reboot:"
  note "then run this script again over SSH, looking at the Mac, for its Apple Account, apps, Instagram and Discord."
fi

# ── Start ───────────────────────────────────────────────────────────────────

if gui_session; then
  sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.hermes-agent" || true
  ok "Hermes is running"
elif sudo test -e /etc/kcpassword && gum confirm "Reboot now? macOS then logs Hermes in and starts it."; then
  sudo shutdown -r now
else
  warn "Hermes starts once macOS logs $agent in: reboot when you are ready."
fi

# ── Check: the local model, and an event end to end ────────────────────────

uzu_port="$(setting server.uzu.port)"
uzu_model="$(setting server.uzu.model)"
uzu_url="http://127.0.0.1:$uzu_port/v1"
uzu_ask() { # system prompt, user message, extra JSON fields
  curl -fsS --max-time 120 "$uzu_url/chat/completions" -H 'Content-Type: application/json' \
    -d "$("$JQ" -n --arg m "$uzu_model" --arg s "$1" --arg u "$2" --argjson x "${3:-{\}}" \
      '{model: $m, messages: [{role: "system", content: $s}, {role: "user", content: $u}],
        temperature: 0, max_tokens: 40, enable_thinking: false} + $x')" \
    | "$JQ" -r '.choices[0].message.content'
}

if gui_session && [ "$(setting server.uzu.enable)" = 1 ]; then
  step "The local model (uzu)"
  if ! curl -fsS "$uzu_url/models" >/dev/null 2>&1; then
    note "At its first start uzu downloads its model (about 5 GB): this can take a while."
    gum spin --title "Waiting for uzu" -- bash -c \
      "for _ in \$(seq 360); do curl -fsS '$uzu_url/models' >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1" || true
  fi
  if answer="$(uzu_ask "Answer with one word." "Say ready.")" && [ -n "$answer" ]; then
    ok "uzu answers ($uzu_model): $answer"
    # The events daemon's own question (hermes_events/triage.py), on an invitation.
    verdict="$(uzu_ask "You screen events for a person's assistant. Decide whether this event may call for the person to do, decide or know something. Answer with the JSON only." \
      "A new message on whatsapp from Martin (direct chat): on prend un verre ce soir ?" \
      '{"response_format": {"type": "json_schema", "json_schema": {"name": "triage", "schema": {"type": "object", "properties": {"may_need_the_user": {"type": "boolean"}, "urgency": {"type": "string", "enum": ["now", "today", "later"]}}, "required": ["may_need_the_user", "urgency"], "additionalProperties": false}}}}' || true)"
    if [ "$("$JQ" -r '.may_need_the_user' <<< "$verdict" 2>/dev/null)" = true ]; then
      ok "Its typed triage flags an invitation: $verdict"
    else
      warn "Its triage did not flag a test invitation: ${verdict:-no answer}"
    fi
  else
    warn "uzu does not answer at $uzu_url: see $agent_home/Library/Logs/uzu.log"
  fi

  events_port="$(setting server.hermes.events.port)"
  webhook_health="http://127.0.0.1:$(setting server.hermes.events.webhookPort)/health"
  # The gateway was just restarted (Start, above): give it a minute.
  [ "$(setting server.hermes.events.enable)" = 1 ] && gum spin --title "Waiting for Hermes' webhook server" -- bash -c \
    "for _ in \$(seq 30); do curl -fsS '$webhook_health' >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" || true
  if [ "$(setting server.hermes.events.enable)" = 1 ] \
    && curl -fsS --max-time 5 "$webhook_health" >/dev/null 2>&1 \
    && gum confirm "Send a fake WhatsApp message through Hermes' events? A proposal should then reach your Telegram main chat."; then
    # A message as wacli would post it, signed the same way (X-Wacli-Signature),
    # from an id no real account has, so a "yes, answer him" reaches nobody.
    body="$("$JQ" -cn --arg id "setup-test-$(date +%s)" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{Chat: "setup-test@s.whatsapp.net", ID: $id, SenderJID: "setup-test@s.whatsapp.net", Timestamp: $ts,
        FromMe: false, ChatName: "Martin (setup test, not a real person)", Text: "On prend un verre ce soir ?"}')"
    webhook_secret="$(sudo sed -n 's/^WEBHOOK_SECRET=//p' "$secrets")"
    signature="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$webhook_secret" -hex | sed 's/^.*= //')"
    unset webhook_secret
    if curl -fsS --max-time 10 "http://127.0.0.1:$events_port/whatsapp" -H "X-Wacli-Signature: $signature" \
      -H 'Content-Type: application/json' -d "$body" >/dev/null; then
      ok "Sent: within $(( $(setting server.hermes.events.batchSeconds) / 60 + 1 )) minutes or so, Hermes should propose something in Telegram"
      note "Nothing? See $agent_home/Library/Logs/hermes-events.log and ~/.hermes/logs on the Hermes account."
    else
      warn "The events daemon does not answer on port $events_port: see $agent_home/Library/Logs/hermes-events.log"
    fi
  fi
fi

gum style --border rounded --padding "0 2" --foreground 42 "The server is set up." \
  "$(gum style --faint 'Message your bot on Telegram. Later changes: edit, push, sudo server-rebuild.')"
