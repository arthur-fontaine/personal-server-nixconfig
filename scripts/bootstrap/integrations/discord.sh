# Discord, in a tab Hermes' events keep open in its Chrome. Discord keeps its
# session in the site's storage, not a cookie this script can read, so your
# "logged in" is what is recorded.
integration_on discord || return 0
step "Integration · Discord"

discord_marker="$agent_home/.local/state/hermes-events/discord-logged-in"
if ! on_hermes_screen; then
  warn "Discord's login needs Hermes' desktop on the Mac's screen: run this script again then, over SSH."
elif as_root test -e "$discord_marker" \
  && keep "Hermes was logged in to Discord (it logs in again from 1Password when needed)"; then
  :
else
  hermes_lit 1
  note "On the Mac's screen, in Chrome, the Discord tab (Hermes' events keep it open): log in."
  note "Scanning the QR code with Discord's phone app is easiest. Allow notifications if it asks."
  if gum confirm --affirmative "Logged in" --negative "Skip" "Logged in to Discord?"; then
    as_agent sh -c 'mkdir -p "$(dirname "$1")" && touch "$1"' _ "$discord_marker"
    ok "Hermes is logged in to Discord"
  fi
  hermes_lit "$(setting server.energy.displayBrightness)"
fi
