# ── Apple apps ──────────────────────────────────────────────────────────────
# Messages, Notes, Reminders, Contacts, Calendar and Find My act on the Apple
# Account the Hermes account is signed in to, and each asks macOS (TCC) the
# first time it is used. A permission belongs to the process that asked: here,
# as for the gateway, the launcher that launchd starts in Hermes' session, so
# the dialogs show on Hermes' desktop and what you allow is the gateway's.

# MobileMeAccounts stays empty on recent macOS: the iCloud account is the
# AppleAccount one in the accounts database, which takes Full Disk Access
# (the launcher's) to read.
apple_account() {
  as_agent /usr/bin/defaults read MobileMeAccounts Accounts 2>/dev/null | grep -q AccountID && return 0
  as_gateway "/usr/bin/sqlite3 'file:$agent_home/Library/Accounts/Accounts4.sqlite?mode=ro' \
    \"select count(*) from ZACCOUNT a join ZACCOUNTTYPE t on a.ZACCOUNTTYPE = t.Z_PK
      where t.ZIDENTIFIER = 'com.apple.account.AppleAccount' and a.ZACTIVE = 1\" | grep -qx '[1-9][0-9]*'" >/dev/null 2>&1
}

# One app: run its check, which also brings up its dialog, until it passes.
# `tell application` launches an app that is not running, but may send it the
# command before it is ready: AppleScript then fails with "Application isn't
# running" (-600), which is not a refusal, so that is retried for a while.
# AppleScript's own launch does not always bring the app up, and it then
# answers -600 through every retry: each retry launches the app itself, hidden.
apple_app() {
  local what="$1" check="$2" out tries passed app
  app="$(sed -n 's/.*tell application \\\{0,1\}"\([^"\\]*\)\\\{0,1\}".*/\1/p' <<< "$check")"
  while :; do
    tries=0
    while :; do
      passed=0
      out="$(as_gateway "$check" 2>&1)" && passed=1
      [ "$passed" = 1 ] || [[ "$out" != *"(-600)"* ]] || [ "$tries" -ge 15 ] && break
      [ -n "$app" ] && as_gateway "/usr/bin/open -g -j -a '$app'" >/dev/null 2>&1 || true
      tries=$((tries + 1))
      sleep 2
    done
    if [ "$passed" = 1 ]; then
      ok "$what"
      return 0
    fi
    warn "$what: not allowed yet${out:+ ($(head -c 200 <<< "$out"))}"
    note "Click Allow on the Mac's screen, or turn it on in System Settings → Privacy & Security."
    gum confirm --affirmative "Check again" --negative "Skip" "Allowed?" || return 0
  done
}

apple_apps() {
  note "Hermes' Apple Account:"
  while ! apple_account; do
    if ! full_disk_access; then
      warn "Hermes cannot see its Apple Account without Full Disk Access: grant it first (Permissions)."
      gum confirm --affirmative "Check again" --negative "Skip" "Granted?" || return 0
      continue
    fi
    note "On the Mac's screen, in the System Settings that opens, sign in with your Apple Account,"
    note "then in iCloud turn on Messages, Notes, Reminders, Contacts, Calendars and Find My Mac."
    hermes_gui /usr/bin/open "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings" || true
    gum confirm --affirmative "Check again" --negative "Skip" "Signed in?" || return 0
  done
  ok "$agent is signed in to an Apple Account"

  note "Each Apple app's permission (dialogs on the Mac's screen):"
  apple_app "Reminders" 'remindctl authorize >/dev/null 2>&1; [ "$(remindctl status --plain)" = full-access ]'
  apple_app "Notes" "osascript -e 'tell application \"Notes\" to count notes'"
  apple_app "Contacts" "osascript -e 'tell application \"Contacts\" to count people'"
  apple_app "Calendar" "osascript -e 'tell application \"Calendar\" to count calendars'"
  apple_app "Messages (sending)" "osascript -e 'tell application \"Messages\" to count accounts'"
  # Moving, flagging or marking a mail: iMCP only reads it.
  apple_app "Mail (moving, flagging)" "osascript -e 'tell application \"Mail\" to count accounts'"
  # Unasked, an osascript to System Events waits on its dialog until it times out.
  apple_app "System Events" "osascript -e 'tell application \"System Events\" to count processes'"

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
}

imcp_prefs="$agent_home/Library/Containers/co.dododo.iMCP/Data/Library/Preferences/co.dododo.iMCP"
# What iMCP serves Hermes (modules/hermes/agent/apple.nix); Maps uses Location.
# (voicemailEnabled is in its binary; phone's, too short for `strings` to see
# in a Swift binary, follows the same "<service>Enabled".)
imcp_services=(calendar contacts location mail music shortcuts voiceMemos weather phone voicemail)

# The services iMCP does not serve yet, one per line.
# Read by the launcher: its container is closed to processes without Full
# Disk Access (app_defaults, lib.sh).
imcp_missing() {
  local service prefs
  prefs="$(as_gateway "/usr/bin/defaults read '$imcp_prefs'" 2>/dev/null || true)"
  for service in "${imcp_services[@]}"; do
    grep -q "^ *${service}Enabled = 1;" <<< "$prefs" || echo "$service"
  done
}

# Mail on in iMCP's settings is not Mail read: iMCP is sandboxed and reads
# ~/Library/Mail only through the folder its dialog was given, and without it
# every search failed ("Mail access is unavailable. The index and its live
# WAL files must be readable", Envelope's MailError.indexNotReadable) while
# the switch said on. So this asks iMCP's server for one message, as Hermes
# does, through the launcher (Local Network).
imcp_mail_reads() {
  local init call
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hermes-agent","version":"0"}}}'
  call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mail_messages_search","arguments":{"limit":1}}}'
  as_gateway "(printf '%s\n' '$init' '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}' '$call'; sleep 15) \
    | timeout 20 /Applications/iMCP.app/Contents/MacOS/imcp-server 2>/dev/null | grep -m1 '\"id\":2' | grep -qv '\"isError\":true'" 2>/dev/null
}

# iMCP reads Mail's own index, ~/Library/Mail/V<n>/MailData/Envelope Index
# (Envelope 0.4.0's Database.location, https://github.com/mattt/Envelope/blob/a90202c94df24b985d101ab5d2cfdf8162bbe9c9/Sources/Envelope/Mail/Database.swift),
# which Mail creates once it has run with an account. Without it, granting
# ~/Library/Mail fails ("no local Envelope Index was found") and iMCP keeps
# no grant, so the index must exist before the folder is chosen.
# Read through the launcher: ~/Library/Mail takes Full Disk Access.
mail_index() {
  as_gateway "ls '$agent_home'/Library/Mail/V*/MailData/'Envelope Index'" >/dev/null 2>&1
}

mail_store() {
  while ! mail_index; do
    warn "Mail has no mailbox on this Mac yet: iMCP has nothing to read."
    note "In Mail, which opens on the Mac's screen, add your mail account (or turn on Mail in"
    note "System Settings → Apple Account → iCloud), and wait until messages show up."
    hermes_gui /usr/bin/open -a Mail || true
    gum confirm --affirmative "Check again" --negative "Skip" "Done?" || return 0
  done
  ok "Mail has a mailbox on this Mac"
}

imcp_mail() {
  mail_index || return 0
  while ! imcp_mail_reads; do
    warn "iMCP cannot read Mail yet."
    note "On the Mac's screen, in iMCP's menu, switch Mail off and on, and in its dialog choose"
    note "~/Library/Mail itself (Shift-Cmd-G, type ~/Library/Mail), not a folder inside it."
    note "If it said \"no local Envelope Index was found\" before, choose it again now: it kept nothing."
    gum confirm --affirmative "Check again" --negative "Skip" "Done?" || return 0
  done
  ok "iMCP reads Mail"
}

imcp_apps() {
  local missing init
  note "iMCP: Calendar, Contacts, Mail, Maps, Music, Shortcuts, Voice Memos, Weather, Phone, Voicemail:"
  mail_store
  # iMCP asks for Voice Memos' Recordings folder, which the app creates at
  # its first launch: launched hidden, it is there by the time iMCP asks.
  hermes_gui /usr/bin/open -g -j -a /System/Applications/VoiceMemos.app 2>/dev/null || true
  as_root launchctl kickstart "gui/$agent_uid/org.nix-community.home.imcp" 2>/dev/null || true
  sleep 3
  # Its settings live in its container, which its first launch created.
  app_defaults
  while :; do
    missing="$(imcp_missing | tr '\n' ' ')"
    if [ -z "$missing" ]; then
      ok "iMCP serves all of them"
      break
    fi
    note "On the Mac's screen, click iMCP's icon in the menu bar, then each gray service: $missing"
    note "Allow each dialog. Mail asks for a folder: choose ~/Library/Mail; Voice Memos, its Recordings folder"
    note "(in group.com.apple.VoiceMemos.shared; missing? open Voice Memos once, then click it again);"
    note "Phone and Voicemail, the folder their dialog names (your iPhone's calls and voicemails, through iCloud)."
    note "Leave Reminders, Notes and Messages off: Hermes' skills do those."
    gum confirm --affirmative "Check again" --negative "Skip" "Turned on?" || break
  done
  # imcp-server finds the app over Bonjour, which macOS asks about (Local
  # Network) for iMCP, for imcp-server and for the launcher, each on its own
  # (iMCP's README, "Allowing local network access"). An app started before
  # its access was allowed does not advertise: restart iMCP (its launchd job
  # only waits on `open -W`, so it is the app that has to go).
  as_root pkill -xu "$agent_uid" iMCP 2>/dev/null || true
  sleep 2
  as_root launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.imcp" >/dev/null 2>&1 || true
  sleep 5
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hermes-agent","version":"0"}}}'
  apple_app "iMCP reachable from Hermes (Local Network)" \
    "(printf '%s\n' '$init'; sleep 15) | timeout 20 /Applications/iMCP.app/Contents/MacOS/imcp-server 2>/dev/null | grep -m1 -q serverInfo"
  imcp_mail
}

step "Hermes' Apple Account and apps"
if ! on_hermes_screen; then
  warn "They need Hermes' desktop on the Mac's screen: it asks for them once macOS has logged it in (reboot)."
elif apple_account && as_gateway 'imsg chats --limit 1 | grep -q .' >/dev/null 2>&1 && [ -z "$(imcp_missing)" ] \
  && imcp_mail_reads && keep "$agent is signed in to an Apple Account, Hermes reads your messages, iMCP serves its apps"; then
  :
elif needs "Hermes' Apple Account and apps" \
  && gum confirm "Set up Hermes' Apple apps (iMessage, Notes, Reminders, Contacts, Calendar, Mail, Find My)?"; then
  hermes_lit 1
  apple_apps
  hermes_lit "$(setting server.energy.displayBrightness)"
fi

# ── Xcode's Apple Account, which signs the Hermes app ───────────────────────
# xcodebuild's automatic signing (hermes-app, docs/app.md) uses the Apple
# Account signed in to Xcode on Hermes' account, in its login keychain: only
# Xcode's own window signs in. A free account is a Personal Team there.
xcode_signing() { as_agent /usr/bin/defaults read com.apple.dt.Xcode 2>/dev/null | grep -q 'teamID ='; }
if [ "$(setting server.hermes.app.delivery.enable)" = 1 ]; then
  step "Xcode's Apple Account (signing the Hermes app)"
  if ! on_hermes_screen; then
    warn "It needs Hermes' desktop on the Mac's screen: it asks once macOS has logged it in (reboot)."
  elif xcode_signing && keep "Hermes' Xcode is signed in to an Apple Account"; then
    :
  elif needs "Xcode's Apple Account" && gum confirm "Sign Hermes' Xcode in to your Apple Account, to sign the app?"; then
    hermes_lit 1
    while ! xcode_signing; do
      note "On the Mac's screen, in Xcode: Xcode → Settings… → Accounts → + → Apple Account, and sign in"
      note "(a free account works: it becomes a Personal Team). Xcode not there yet? It installs with the configuration."
      hermes_gui /usr/bin/open -a Xcode || true
      gum confirm --affirmative "Check again" --negative "Skip" "Signed in?" || break
    done
    xcode_signing && ok "Hermes' Xcode is signed in to an Apple Account"
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
fi
