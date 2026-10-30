# Sourced by scripts/bootstrap-macos.sh, in its order.
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
  if ask "Set up Hermes' Apple apps (iMessage, Notes, Reminders, Contacts, Calendar, Find My)?"; then
    hermes_lit 1
    apple_apps
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
  if ! integration_on instagram; then
    :
  elif instagram_logged_in; then
    ok "Hermes is logged in to Instagram"
  elif ask "Log Hermes in to your Instagram?"; then
    hermes_lit 1
    instagram_login
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
  if ! integration_on discord; then
    :
  elif sudo test -e "$discord_marker"; then
    ok "Hermes was logged in to Discord (it logs in again from 1Password when needed)"
  elif ask "Log Hermes in to your Discord?"; then
    hermes_lit 1
    discord_login
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
else
  warn "Hermes' Apple apps, Instagram and Discord need its desktop on the Mac's screen, which it is after a reboot:"
  note "then run this script again over SSH, looking at the Mac, for its Apple Account, apps, Instagram and Discord."
fi
