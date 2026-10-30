# Sourced by scripts/bootstrap-macos.sh, in its order.
# ── Integrations: your other services, each optional ───────────────────────
# Written to hosts/local.nix (server.hermes.integrations); the steps below set
# up only those that are on. Apple's apps are always there.

# name|label (no commas: gum's --selected is comma-separated)
integration_choices=(
  "whatsapp|WhatsApp: read and send your messages and see new ones"
  "instagram|Instagram: DMs and posts and stories and its notifications"
  "discord|Discord: DMs and servers and its notifications"
  "homeassistant|Home Assistant: your devices and their changes"
  "homekit|HomeKit: your home's accessories (installs HomeClaw from the App Store)"
  "onepassword|1Password: logins Hermes fills in without seeing them"
  "runpod|RunPod: GPU pods and pods left running"
  "github|GitHub notifications as events"
)
integration_on() { [ "$(setting "server.hermes.integrations.$1.enable")" = 1 ]; }
integrations_now() {
  local line names=()
  for line in "${integration_choices[@]}"; do integration_on "${line%%|*}" && names+=("${line%%|*}"); done
  echo "${names[*]:-none}"
}

step "Integrations"
if grep -q 'integrations' "$local_nix" 2>/dev/null \
  && ! gum confirm --default=false "Integrations: $(integrations_now). Change them?"; then
  ok "Integrations: $(integrations_now)"
else
  note "Your other services Hermes may use, each acting as you there (space to pick, enter to confirm)."
  labels=() selected=()
  for line in "${integration_choices[@]}"; do
    labels+=("${line#*|}")
    integration_on "${line%%|*}" && selected+=("${line#*|}")
  done
  picked="$(IFS=,; gum choose --no-limit --selected="${selected[*]:-}" "${labels[@]}")" || picked=""
  patch="{}"
  for line in "${integration_choices[@]}"; do
    on=false
    grep -qxF "${line#*|}" <<< "$picked" && on=true
    patch="$("$JQ" -c --arg n "${line%%|*}" --argjson on "$on" '.[$n] = {enable: $on}' <<< "$patch")"
  done
  text="$(REPO="$REPO_DIR" HOST="$HOST" \
    PATCH="$("$JQ" -cn --argjson i "$patch" '{server: {hermes: {integrations: $i}}}')" \
    nix eval --impure --raw --file "$REPO_DIR/scripts/lib/set-host.nix")"
  printf '%s' "$text" > "$local_nix"
  ok "Integrations: $(integrations_now)"
fi

# RunPod's key, when that integration is on (its MCP server, its events).
if integration_on runpod && ! sudo grep -q '^RUNPOD_API_KEY=.' "$secrets"; then
  runpod="$(gum input --password --header "RunPod API key (https://www.runpod.io/console/user/settings; empty to skip)" | tr -d '[:space:]')"
  if [ -n "$runpod" ]; then
    others="$(sudo grep -v '^RUNPOD_API_KEY=' "$secrets" || true)"
    printf '%s\nRUNPOD_API_KEY=%s\n' "$others" "$runpod" | sed '/^$/d' | write_secret "$secrets"
    ok "RunPod: key written"
  fi
  unset runpod others
fi

# Home Assistant, when that integration is on: its address and a long-lived
# token, both checked from this Mac before they are kept (the URL in
# hosts/local.nix, HASS_TOKEN in the secrets file), and checked again on
# every run.
ha_api() { # url token → the HTTP status of /api/ (000: nothing answers)
  local auth=()
  [ -n "${2:-}" ] && auth=(-H "Authorization: Bearer $2")
  # (An empty array under set -u fails in macOS' bash 3.2, hence the + form.)
  # curl fails when nothing answers, which would end the script (set -e); its 000 says so.
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 ${auth[@]+"${auth[@]}"} "${1%/}/api/" || true
}
if integration_on homeassistant; then
  ha_url="$(setting server.hermes.homeassistant.url)"
  ha_token="$(sudo sed -n 's/^HASS_TOKEN=//p' "$secrets")"
  if [ -n "$ha_token" ] && [ "$(ha_api "$ha_url" "$ha_token")" = 200 ]; then
    ok "Home Assistant answers at $ha_url, and takes Hermes' token"
  else
    step "Home Assistant"
    [ -n "$ha_token" ] && warn "Home Assistant does not answer at $ha_url with the saved token (status $(ha_api "$ha_url" "$ha_token"))."
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
      note "$ha_url/profile/security"
      launchctl print "gui/$(id -u)" >/dev/null 2>&1 && /usr/bin/open "$ha_url/profile/security" 2>/dev/null || true
      ha_token="$(gum input --password --header "Long-lived access token (empty to skip)" | tr -d '[:space:]')"
      [ -n "$ha_token" ] || break
      status="$(ha_api "$ha_url" "$ha_token")"
      if [ "$status" = 200 ]; then
        others="$(sudo grep -v '^HASS_TOKEN=' "$secrets" || true)"
        printf '%s\nHASS_TOKEN=%s\n' "$others" "$ha_token" | sed '/^$/d' | write_secret "$secrets"
        if [ "$ha_url" != "$(setting server.hermes.homeassistant.url)" ]; then
          text="$(REPO="$REPO_DIR" HOST="$HOST" \
            PATCH="$("$JQ" -cn --arg u "$ha_url" '{server: {hermes: {homeassistant: {url: $u}}}}')" \
            nix eval --impure --raw --file "$REPO_DIR/scripts/lib/set-host.nix")"
          printf '%s' "$text" > "$local_nix"
        fi
        ok "Home Assistant takes the token: Hermes can use it"
        break
      fi
      warn "Home Assistant refused that token (status $status)."
      gum confirm --affirmative "Try again" --negative "Skip" "Retry?" || break
    done
  fi
  unset ha_token others status
fi
