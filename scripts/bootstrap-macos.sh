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
  opencode="$(gum input --password --header "OpenCode Zen API key (https://opencode.ai/auth)")"
  runpod="$(gum input --password --header "RunPod API key (https://www.runpod.io/console/user/settings)")"
  step "Your Telegram bot"
  bot_token="$(new_bot_token)"
  bot="$(tg "$bot_token" getMe | "$JQ" -r .result.username)"
  owner="$(owner_id "$bot_token" "$bot")"
  sudo mkdir -p "$(dirname "$secrets")"
  printf 'OPENCODE_ZEN_API_KEY=%s\nRUNPOD_API_KEY=%s\nTELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\n' \
    "$opencode" "$runpod" "$bot_token" "${owner//[^0-9]/}" | write_secret "$secrets"
  unset opencode runpod
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

if as_agent gh auth status >/dev/null 2>&1; then
  ok "Hermes can push to GitHub"
else
  step "GitHub access for Hermes"
  note "A fine-grained token for this repository only, with Contents: read and write."
  note "Whoever can push here can change the whole Mac through sudo server-rebuild."
  token="$(gum input --password --header "GitHub token (empty to skip)")"
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
}

if gui_session && [ "$(stat -f %Su /dev/console)" = "$agent" ]; then
  if gum confirm "Set up Hermes' Apple apps (iMessage, Notes, Reminders, Contacts, Calendar, Find My)?"; then
    hermes_lit 1
    apple_apps
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
else
  warn "Hermes' Apple apps need its desktop on the Mac's screen, which it is after a reboot:"
  note "then run this script again over SSH, looking at the Mac, for its Apple Account and apps."
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

gum style --border rounded --padding "0 2" --foreground 42 "The server is set up." \
  "$(gum style --faint 'Message your bot on Telegram. Later changes: edit, push, sudo server-rebuild.')"
