# ── Sideload: your devices ──────────────────────────────────────────────────
# The iPhones and iPads the sideload service installs apps on (docs/sideload.md).
# A device must be plugged into this Mac once, by cable: paired (you tap
# Trust on it), with Developer Mode on; from then on Xcode reaches it over the
# local network. Also run at Hermes' login (scripts/hermes-setup.sh): done
# when a device is paired, or when you said you have none for now. Through
# the launcher, in Hermes' session, as the sideload job runs (as Hermes' account).
[ "$(setting server.sideload.enable)" = 1 ] || return 0
step "Sideload: your iPhones and iPads"

# Seconds between refreshes (a test shortens it).
app_refresh="${app_refresh:-15}"
app_skipped="$agent_home/.local/state/hermes-setup/sideload-devices-skipped"
app_devices() { as_gateway "sideload devices" 2>/dev/null || true; }
# Ready: paired, with Developer Mode on (an install fails without it).
app_ready='.devices[]? | select(.paired and (.developer_mode == null or .developer_mode == "enabled"))'
app_paired() { "$JQ" -r "[$app_ready] | length" <<< "$1" 2>/dev/null || echo 0; }
app_names() { "$JQ" -r "[$app_ready | .name] | join(\", \")" <<< "$1" 2>/dev/null; }

# Seen by devicectl now; the others are only remembered by sideload.
app_live='.devices[]? | select(has("transport"))'

# The state, one "note|…" or "warn|…" line each: printed only when it changes.
app_state() {
  local error unreached
  error="$("$JQ" -r '.error // empty' <<< "$1" 2>/dev/null || true)"
  if [ -n "$error" ]; then
    # cli.py's "devicectl list devices failed: <devicectl's own words>".
    error="${error#devicectl list devices failed: }"
    error="${error#ERROR: }"
    echo "warn|Xcode can't list the devices: $(printf '%s\n' "$error" | grep -m 1 . || true)"
  fi
  unreached="$(app_unreached "$1")"
  if [ "$unreached" -gt 0 ]; then
    echo "warn|Your iPhone is plugged in but Xcode can't reach it yet. Unplug it and plug it back in, unlocked;"
    echo "warn|then allow the accessory on the Mac's screen and tap Trust on the iPhone (enter its passcode)."
    echo "warn|If the iPhone doesn't ask, check Settings › Privacy & Security › Wired Accessories on it."
  fi
  if [ "$("$JQ" -r '.devices | length' <<< "$1" 2>/dev/null || echo 0)" = 0 ]; then
    [ "$unreached" -gt 0 ] || echo "note|No iPhone or iPad yet."
    return 0
  fi
  "$JQ" -r '.devices[] | "note|\(.name // .id) (\(.model // "?"), iOS \(.os // "?")): " + (
      if (has("transport") | not) then "known, not seen by Xcode now"
      elif (.paired | not) then "not paired yet: unlock it and tap Trust"
      elif .developer_mode != null and .developer_mode != "enabled" then "paired; turn on Developer Mode (Settings → Privacy & Security), then restart it"
      elif .reachable then "ready" + (if .transport == "wired" then " (by cable; Wi-Fi once unplugged)" else " (over Wi-Fi)" end)
      else "paired, not reachable now (another network, or asleep)" end)' <<< "$1" 2>/dev/null || true
}

app_print() {
  local line
  while IFS= read -r line; do
    case "$line" in
      warn\|*) warn "${line#warn|}" ;;
      *) note "${line#note|}" ;;
    esac
  done <<< "$1"
}

# The USB serial number of each iPhone and iPad plugged in ("?" when it has
# none): an iPhone's is its UDID without the dash. About 0.2 s.
app_usb() {
  system_profiler SPUSBHostDataType 2>/dev/null | awk '
    /^ *[^ :][^:]*:$/ { if (dev) print "?"; dev = ($0 ~ /^ *(iPhone|iPad)/); next }
    dev && /Serial Number:/ { sub(/.*Serial Number: */, ""); print; dev = 0 }
    END { if (dev) print "?" }' || true
}

# How many iPhones and iPads are on USB with no device devicectl lists for
# them. Plugged in while Hermes' session was locked, macOS parks its "allow
# this accessory" request and never asks again: unplugging it makes it ask.
app_unreached() {
  local ids serial count=0
  ids=" $("$JQ" -r "[$app_live | .id | ascii_upcase | gsub(\"-\"; \"\")] | join(\" \")" <<< "$1" 2>/dev/null || true) "
  while IFS= read -r serial; do
    [ -n "$serial" ] || continue
    if [ "$serial" = "?" ]; then
      "$JQ" -e "[$app_live | select(.transport == \"wired\")] | length > 0" <<< "$1" >/dev/null 2>&1 || count=$((count + 1))
    else
      case "$ids" in *" $(printf '%s' "$serial" | tr '[:lower:]' '[:upper:]') "*) ;; *) count=$((count + 1)) ;; esac
    fi
  done <<< "$(app_usb)"
  echo "$count"
}

# Pairs what devicectl sees plugged in and not paired: the device asks to
# Trust this Mac. True when it tried one.
app_pair() {
  local udid tried=1
  for udid in $("$JQ" -r "$app_live | select(.paired | not) | .id" <<< "$1" 2>/dev/null); do
    case " $app_asked " in *" $udid "*) continue ;; esac
    app_asked="$app_asked $udid"
    note "Pairing $udid: on the device, tap Trust and enter its passcode."
    as_gateway "xcrun devicectl manage pair --device '$udid'" >/dev/null 2>&1 || true
    tried=0
  done
  return "$tried"
}

app_devices_loop() {
  local json state shown="" choice key rc started
  app_asked=""
  note "Plug each iPhone or iPad into this Mac by cable, once, while Hermes' session is unlocked,"
  note "with the iPhone unlocked too, and watch both screens: the Mac asks to allow the accessory,"
  note "then the iPhone asks to Trust this Mac. Both must then share a Wi-Fi network."
  while :; do
    json="$(app_devices)"
    ! app_pair "$json" || json="$(app_devices)"
    state="$(app_state "$json")"
    if [ "$state" != "$shown" ]; then
      app_print "$state"
      shown="$state"
    fi
    # Not gum choose --timeout: on a timeout gum 0.17 leaves its menu on the
    # screen and writes "timed out" under it, so the menus piled up every
    # 15 s. One prompt line, erased after each wait, keeps the screen still.
    printf '  \033[2m%s\033[0m' "Refreshes every $app_refresh s. Enter: refresh now · d: done · n: I have no device for now " >&2
    rc=0 started=$SECONDS
    IFS= read -r -s -n 1 -t "$app_refresh" key || rc=$?
    printf '\r\033[2K' >&2
    # bash 3.2's read returns 1 both on its timeout and at the end of the
    # input: failing at once means there is no terminal to read.
    if [ "$rc" != 0 ]; then
      [ $((SECONDS - started)) -gt 0 ] || return 0
      continue
    fi
    case "$key" in
      d|D) choice=Done ;;
      n|N) choice="I have no device for now" ;;
      *) continue ;;
    esac
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
    if [ "$(setting server.hermes.app.delivery.enable)" = 1 ]; then
      if ! app_team="$(sideload_team)"; then
        case "$app_team" in
          "no Apple Account"*) warn "Xcode isn't signed in to an Apple Account yet: run bootstrap-macos.sh sideload-account first, then this step again." ;;
          *) warn "No install yet: $app_team" ;;
        esac
      elif ask "Install the Hermes app on them now (a few minutes, in the background)?"; then
        # Its answer is kept: a refusal (no team, unknown app) is the only
        # word of why nothing installs.
        if app_out="$(as_gateway "sideload install hermes --reason 'first install'" 2>&1)"; then
          ok "Installing in the background: sideload status hermes shows where it is (log: ~$agent/Library/Logs/sideload.log)."
          note "Once it is on the iPhone, trust its developer there before opening it:"
          note "Settings › General › VPN & Device Management › your Apple Account › Trust."
        else
          warn "Could not start the install: $("$JQ" -r '.error // empty' <<< "$app_out" 2>/dev/null | grep . || echo "$app_out")"
        fi
      fi
    fi
  fi
fi
