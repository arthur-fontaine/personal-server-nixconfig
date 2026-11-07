# ── Sideload: iOS apps on your iPhone and iPad ──────────────────────────────
# Whether this Mac installs iOS apps on your devices and keeps them signed
# (server.sideload, docs/sideload.md): any app Hermes is asked for (an .ipa,
# an Xcode project), and the Hermes app when app.sh turned it on (that turns
# the service on by itself). Before xcode.sh and system.sh: it writes
# hosts/local.nix. Xcode's account is sideload-account.sh, your devices
# sideload-devices.sh, both once Hermes' session is there.
step "Sideload"

if [ "$(setting server.hermes.app.delivery.enable)" = 1 ]; then
  ok "Sideload: on, for the Hermes app (and any other app you ask Hermes for)"
elif grep -q 'sideload' "$local_nix" 2>/dev/null \
  && keep "Sideload: $([ "$(setting server.sideload.enable)" = 1 ] && echo on || echo off)"; then
  :
else
  note "Hermes can install iOS apps on your iPhone or iPad from this Mac (an .ipa, an Xcode project),"
  note "signed with your Apple Account (a free one works: 3 apps per device, re-signed every few days here)."
  on=false
  gum confirm "Let Hermes install apps on your iPhone or iPad?" && on=true
  set_host "$("$JQ" -cn --argjson on "$on" '{server: {sideload: {enable: $on}}}')"
  ok "Sideload: $([ "$on" = true ] && echo on || echo off)"
fi
if [ "$(setting server.sideload.enable)" = 1 ] && [ "$(setting server.xcode.enable)" != 1 ]; then
  warn "Sideload needs Xcode, which is off (server.xcode.enable): the configuration will refuse it."
fi
