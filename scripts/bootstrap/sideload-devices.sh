# ── Sideload: your devices ──────────────────────────────────────────────────
# The iPhones and iPads the sideload service installs apps on (docs/sideload.md).
# A device must be plugged into this Mac once, by cable: paired (you tap
# Trust on it), with Developer Mode on; from then on Xcode reaches it over the
# local network. Also run at Hermes' login (scripts/hermes-setup.sh): done
# when a device is paired, or when you said you have none for now. Through
# the launcher, in Hermes' session, as the sideload job runs (as Hermes' account).
[ "$(setting server.sideload.enable)" = 1 ] || return 0
step "Sideload: your iPhones and iPads"

app_skipped="$agent_home/.local/state/hermes-setup/sideload-devices-skipped"
app_devices() { as_gateway "sideload devices" 2>/dev/null || true; }
# Ready: paired, with Developer Mode on (an install fails without it).
app_ready='.devices[]? | select(.paired and (.developer_mode == null or .developer_mode == "enabled"))'
app_paired() { "$JQ" -r "[$app_ready] | length" <<< "$1" 2>/dev/null || echo 0; }
app_names() { "$JQ" -r "[$app_ready | .name] | join(\", \")" <<< "$1" 2>/dev/null; }

app_show() {
  local line
  if [ "$("$JQ" -r '.devices | length' <<< "$1" 2>/dev/null || echo 0)" = 0 ]; then
    note "No iPhone or iPad yet."
    return 0
  fi
  while IFS= read -r line; do
    note "$line"
  done < <("$JQ" -r '.devices[] | "\(.name // .id) (\(.model // "?"), iOS \(.os // "?")): " + (
      if (.paired | not) then "not paired yet: unlock it and tap Trust"
      elif .developer_mode != null and .developer_mode != "enabled" then "paired; turn on Developer Mode (Settings → Privacy & Security), then restart it"
      elif .reachable then "ready" + (if .transport == "wired" then " (by cable; Wi-Fi once unplugged)" else " (over Wi-Fi)" end)
      else "paired, not reachable now (another network, or asleep)" end)' <<< "$1")
}

# Pairs what is plugged in and not paired: the device asks to Trust this Mac.
# True when it tried one.
app_pair() {
  local udid tried=1
  for udid in $("$JQ" -r '.devices[]? | select(.paired | not) | .id' <<< "$1" 2>/dev/null); do
    case " $app_asked " in *" $udid "*) continue ;; esac
    app_asked="$app_asked $udid"
    note "Pairing $udid: on the device, tap Trust and enter its passcode."
    as_gateway "xcrun devicectl manage pair --device '$udid'" >/dev/null 2>&1 || true
    tried=0
  done
  return "$tried"
}

app_devices_loop() {
  local json choice rc
  app_asked=""
  note "Plug each iPhone or iPad into this Mac by cable, once, and unlock it. A dialog may also"
  note "ask on the Mac's screen to allow the accessory: allow it. Both must then share a Wi-Fi network."
  while :; do
    json="$(app_devices)"
    ! app_pair "$json" || json="$(app_devices)"
    app_show "$json"
    rc=0
    choice="$(gum choose --timeout 15s --header "It refreshes by itself every 15 seconds." \
      "Refresh now" "Done" "I have no device for now")" || rc=$?
    # gum's timeout (exit 124): the automatic refresh.
    [ "$rc" = 124 ] && continue
    [ "$rc" = 0 ] || return 0
    case "$choice" in
      Done) return 0 ;;
      "I have no device for now")
        as_agent mkdir -p "$(dirname "$app_skipped")" && as_agent touch "$app_skipped"
        note "Not asked again at each login; run bootstrap-macos.sh sideload-devices to add one."
        return 0
        ;;
    esac
  done
}

if ! gui_session; then
  warn "This needs Hermes' session: it asks once macOS has logged Hermes in (reboot)."
  return 0
fi
app_json="$(app_devices)"
if [ -z "$app_json" ]; then
  warn "sideload does not answer yet (the configuration not applied?): run bootstrap-macos.sh sideload-devices later."
  return 0
fi
app_error="$("$JQ" -r '.error // empty' <<< "$app_json" 2>/dev/null || true)"
[ -z "$app_error" ] || warn "devicectl: $app_error"
if [ "$(app_paired "$app_json")" -gt 0 ] && keep "Apps can be sideloaded on: $(app_names "$app_json")"; then
  :
elif [ "$(app_paired "$app_json")" = 0 ] && as_agent test -e "$app_skipped" && keep "No device to sideload on for now"; then
  :
elif needs "a device to sideload on" && gum confirm "Pair an iPhone or iPad now?"; then
  as_agent rm -f "$app_skipped"
  hermes_lit 1
  app_devices_loop
  hermes_lit "$(setting server.energy.displayBrightness)"
  app_json="$(app_devices)"
  if [ "$(app_paired "$app_json")" -gt 0 ]; then
    ok "Apps can be sideloaded on: $(app_names "$app_json")"
    if [ "$(setting server.hermes.app.delivery.enable)" = 1 ] \
      && ask "Install the Hermes app on them now (a few minutes, in the background)?"; then
      as_gateway "sideload install hermes --reason 'first install'" >/dev/null 2>&1 \
        && ok "Installing: its log is ~$agent/Library/Logs/sideload.log" \
        || warn "Could not start the install: ask Hermes to install the app."
    fi
  fi
fi
