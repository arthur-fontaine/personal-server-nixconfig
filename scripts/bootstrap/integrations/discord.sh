# Discord, in a tab Hermes' events keep open in its Chrome. Its session is in
# the site's storage, not a cookie, but the tab shows it: logged out, Discord
# sends /channels/... to /login. Chrome lists its tabs on its DevTools port
# (modules/hermes/agent/browser.nix).
integration_on discord || return 0
step "Integration · Discord"

discord_logged_in() {
  curl -s --max-time 5 "http://127.0.0.1:$(setting server.hermes.browserPort)/json/list" 2>/dev/null \
    | grep -q '"url": *"https://discord.com/channels/'
}

if ! on_hermes_screen; then
  warn "Discord's login needs Hermes' desktop on the Mac's screen: it asks for it once macOS has logged it in."
elif discord_logged_in && keep "Hermes is logged in to Discord"; then
  :
elif needs "Discord's login"; then
  hermes_lit 1
  note "On the Mac's screen, in Chrome, the Discord tab (Hermes' events keep it open): log in."
  note "Scanning the QR code with Discord's phone app is easiest. Allow notifications if it asks."
  if gum confirm --affirmative "Check" --negative "Skip" "Logged in?"; then
    while ! discord_logged_in; do
      warn "Hermes' Chrome has no Discord tab on discord.com/channels yet."
      gum confirm --affirmative "Check again" --negative "Skip" "Logged in?" || break
    done
    discord_logged_in && ok "Hermes is logged in to Discord"
  fi
  hermes_lit "$(setting server.energy.displayBrightness)"
fi
