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
    if [ "$("$JQ" -r '.result.has_topics_enabled and .result.allows_users_to_create_topics' <<< "$me")" = true ]; then
      ok "Topics are on: each topic of your chat with @$bot is a sub-chat"
      break
    fi
    step "Topics, for sub-chats in your chat with @$bot"
    note "In @BotFather, tap Open (its Mini App): My bots → @$bot → Bot Settings → Threads Settings."
    # getMe leaves these fields out while they are off.
    if [ "$("$JQ" -r '.result.has_topics_enabled // false' <<< "$me")" != true ]; then
      note "Off: Threaded Mode (getMe has_topics_enabled). Turn \"Threaded Mode\" ON."
    fi
    if [ "$("$JQ" -r '.result.allows_users_to_create_topics // false' <<< "$me")" != true ]; then
      note "Users cannot create topics (getMe allows_users_to_create_topics): turn \"Disallow users to create new threads\" OFF,"
      note "so you can tap + to start a sub-chat."
    fi
    gum confirm --affirmative "Check again" --negative "Skip" "Done?" || break
  done
  while :; do
    me="$(tg "$token" getMe)"
    if [ "$("$JQ" -r .result.can_read_all_group_messages <<< "$me")" = true ]; then
      ok "Privacy mode is off: groups with @$bot work as sub-chats too"
      break
    fi
    step "Groups, for sub-chats outside your DM (optional)"
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
if [ -n "${bot_token:-}" ]; then
  botfather_settings "$bot_token" "$(tg "$bot_token" getMe | "$JQ" -r .result.username)"
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

# ── Start ───────────────────────────────────────────────────────────────────

if gui_session; then
  sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.hermes-agent" || true
  ok "Hermes is running"
elif sudo test -e /etc/kcpassword && gum confirm "Reboot now? macOS then logs Hermes in and starts it; nothing else to run."; then
  sudo shutdown -r now
else
  warn "Hermes starts once macOS logs $agent in: reboot when you are ready."
fi

gum style --border rounded --padding "0 2" --foreground 42 "The server is set up." \
  "$(gum style --faint 'Message your bot on Telegram. Later changes: edit, push, sudo server-rebuild.')"
