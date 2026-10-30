# Sourced by scripts/bootstrap-macos.sh, in its order.
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
  elif ask "Let Hermes read app windows (Find My, through peekaboo)?"; then
    note "In each list that opens, click +, then drag in the file Finder shows (or ⇧⌘G and paste its path)."
    hermes_gui /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture" || true
    hermes_gui /usr/bin/open -R "$launcher" || true
    gum confirm --affirmative "Next" --negative "" "Screen Recording added?" || true
    hermes_gui /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility" || true
    gum confirm --affirmative "Done" --negative "" "Accessibility added?" || true
  fi

  imcp_apps
  integration_on homekit && homeclaw_app
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
