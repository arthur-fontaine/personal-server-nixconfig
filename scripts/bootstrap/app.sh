# ── The Hermes app: built here, installed on your iPhone and iPad ───────────
# Whether this Mac builds the Hermes iOS app and installs it on your devices
# (server.hermes.app.delivery, through the sideload service: docs/sideload.md),
# and the Telegram API id the app logs in to Telegram with. Before xcode.sh and
# system.sh: it writes hosts/local.nix. Signing in Xcode is sideload-account.sh,
# your devices sideload-devices.sh, both once Hermes' session is there.
step "App · on your devices"

if grep -q 'delivery' "$local_nix" 2>/dev/null \
  && keep "The Hermes app: $([ "$(setting server.hermes.app.delivery.enable)" = 1 ] && echo "built here and installed on your devices" || echo "not installed")"; then
  :
else
  note "An iPhone and iPad app for Hermes, built on this Mac, signed with your Apple Account (a free one"
  note "works: Xcode re-signs it every few days by itself) and installed on your devices over Wi-Fi."
  on=false
  gum confirm "Install the Hermes app on your iPhone or iPad?" && on=true
  set_host "$("$JQ" -cn --argjson on "$on" '{server: {hermes: {app: {delivery: {enable: $on}}}}}')"
  ok "The Hermes app: $([ "$on" = true ] && echo on || echo off)"
fi

if [ "$(setting server.hermes.app.delivery.enable)" = 1 ]; then
  [ "$(setting server.xcode.enable)" = 1 ] \
    || warn "The app needs Xcode, which is off (server.xcode.enable): the configuration will refuse it."
  # app-topic.sh, just before, asked whether Hermes serves it.
  [ "$(setting server.hermes.app.enable)" = 1 ] \
    || note "Hermes does not serve the app (App · Hermes' side): it will show your chats, without Hermes' state, questions or pet."
  # The app is a Telegram client of your own account (TDLib), which needs an
  # API id of its own: Telegram gives one per account, at my.telegram.org.
  if [ -n "$(secret_value TELEGRAM_API_ID)" ] && [ -n "$(secret_value TELEGRAM_API_HASH)" ] \
    && keep "The app's Telegram API id: $(secret_value TELEGRAM_API_ID)"; then
    :
  else
    note "The app logs in to Telegram as you, with an API id of your own: on my.telegram.org, log in"
    note "with your phone number, open API development tools and create an app (any name, platform iOS)."
    show_link "https://my.telegram.org/apps"
    api_id="$(gum input --header "api_id (digits; empty to skip)" | tr -d '[:space:]')"
    if [ -n "$api_id" ]; then
      api_hash="$(gum input --password --header "api_hash" | tr -d '[:space:]')"
      set_secret TELEGRAM_API_ID "$api_id"
      set_secret TELEGRAM_API_HASH "$api_hash"
      ok "The app's Telegram API id written"
    else
      warn "No Telegram API id: the app builds, but cannot log in to Telegram."
    fi
  fi
fi
