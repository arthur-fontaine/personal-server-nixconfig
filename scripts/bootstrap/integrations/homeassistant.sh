# Home Assistant: its address and a long-lived token, both checked from this
# Mac before they are kept (the address in hosts/local.nix, HASS_TOKEN in the
# secrets file), and checked again on every run. Before the configuration is
# applied, since the address is part of it.
integration_on homeassistant || return 0
step "Integration · Home Assistant"

ha_api() { # url token → the HTTP status of /api/ (000: nothing answers)
  local auth=()
  [ -n "${2:-}" ] && auth=(-H "Authorization: Bearer $2")
  # (An empty array under set -u fails in macOS' bash 3.2, hence the + form.)
  # curl fails when nothing answers, which would end the script (set -e); its 000 says so.
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 ${auth[@]+"${auth[@]}"} "${1%/}/api/" || true
}

ha_url="$(setting server.hermes.homeassistant.url)"
ha_token="$(secret_value HASS_TOKEN)"
if [ -n "$ha_token" ] && [ "$(ha_api "$ha_url" "$ha_token")" = 200 ] \
  && keep "Home Assistant answers at $ha_url, and takes Hermes' token"; then
  return 0
fi
[ -n "$ha_token" ] && [ "$(ha_api "$ha_url" "$ha_token")" != 200 ] \
  && warn "Home Assistant does not answer at $ha_url with the saved token (status $(ha_api "$ha_url" "$ha_token"))."
while :; do
  ha_url="$(gum input --value "$ha_url" --header "Home Assistant's address, as this Mac reaches it (e.g. http://192.168.1.10:8123)")"
  ha_url="${ha_url%/}"
  status="$(ha_api "$ha_url")"
  if [ "$status" = 000 ]; then
    warn "Nothing answers at $ha_url from this Mac: a wrong address or port, or another network."
    # https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
    note "Or macOS blocks this terminal until you allow it on the local network: if it asked, allow it"
    note "(System Settings → Privacy & Security → Local Network), then try again. Over SSH it is not asked."
    gum confirm --affirmative "Try another" --negative "Skip" "Retry?" && continue
    break
  fi
  # Without a token, Home Assistant's API answers 401: it is there.
  [ "$status" = 401 ] || warn "$ha_url answers, but not like Home Assistant (status $status): checking with a token anyway."
  ok "Home Assistant answers at $ha_url"
  note "Create a token: your profile → Security → Long-lived access tokens → Create token:"
  show_link "$ha_url/profile/security"
  ha_token="$(gum input --password --header "Long-lived access token (empty to skip)" | tr -d '[:space:]')"
  [ -n "$ha_token" ] || break
  status="$(ha_api "$ha_url" "$ha_token")"
  if [ "$status" = 200 ]; then
    set_secret HASS_TOKEN "$ha_token"
    [ "$ha_url" = "$(setting server.hermes.homeassistant.url)" ] \
      || set_host "$("$JQ" -cn --arg u "$ha_url" '{server: {hermes: {homeassistant: {url: $u}}}}')"
    ok "Home Assistant takes the token: Hermes can use it"
    break
  fi
  warn "Home Assistant refused that token (status $status)."
  gum confirm --affirmative "Try again" --negative "Skip" "Retry?" || break
done
unset ha_token status
