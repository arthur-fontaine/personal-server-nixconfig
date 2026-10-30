# Instagram, in Hermes' always-open Chrome (modules/hermes/agent/browser.nix):
# its first login is yours, on the Mac's screen, since Instagram trusts a login
# made by hand; later ones come from 1Password.
integration_on instagram || return 0
step "Integration · Instagram"

browser_profile="$agent_home/.hermes/browser-profile"
instagram_logged_in() {
  as_agent /usr/bin/sqlite3 "file:$browser_profile/Default/Cookies?mode=ro&immutable=1" \
    "select count(*) from cookies where host_key like '%instagram.com' and name = 'sessionid';" 2>/dev/null \
    | grep -qx '[1-9][0-9]*'
}

if ! on_hermes_screen; then
  warn "Instagram's login needs Hermes' desktop on the Mac's screen: run this script again then, over SSH."
elif instagram_logged_in && keep "Hermes is logged in to Instagram"; then
  :
elif needs "Instagram's login"; then
  hermes_lit 1
  as_root launchctl kickstart "gui/$agent_uid/org.nix-community.home.chrome" 2>/dev/null || true
  note "On the Mac's screen, in the Chrome window on instagram.com: log in (or out, then in as"
  note "another account), and save the login info. If Instagram offers notifications, turn them on:"
  note "they become Hermes' events. Chrome writes its cookies within half a minute."
  if gum confirm --affirmative "Check" --negative "Skip" "Logged in?"; then
    while ! instagram_logged_in; do
      warn "No Instagram session in Hermes' Chrome yet."
      gum confirm --affirmative "Check again" --negative "Skip" "Logged in?" || break
    done
    instagram_logged_in && ok "Hermes is logged in to Instagram"
  fi
  hermes_lit "$(setting server.energy.displayBrightness)"
fi
