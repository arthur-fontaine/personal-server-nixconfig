# HomeKit, through HomeClaw (an App Store app in Hermes' session): it needs
# Hermes' Apple Account, signed in by apple.sh.
integration_on homekit || return 0
step "Integration · HomeKit"

# HomeClaw is on the App Store only: Apple allows HomeKit nowhere else.
homeclaw_app() {
  local mas
  if [ ! -d /Applications/HomeClaw.app ]; then
    mas="$(mas_tool)"
    # mas installs as root for the App Store account of SUDO_UID: Hermes'.
    if ! as_root launchctl asuser "$agent_uid" env SUDO_UID="$agent_uid" SUDO_GID="$(id -g "$agent")" \
      SUDO_USER="$agent" HOME="$agent_home" "$mas" get 6759682551; then
      note "On the Mac's screen, install HomeClaw from the App Store that opens (Get)."
      hermes_gui /usr/bin/open "macappstore://apps.apple.com/app/id6759682551" || true
      gum confirm --affirmative "Done" --negative "Skip" "Installed?" || return 0
    fi
  fi
  [ -d /Applications/HomeClaw.app ] || { warn "HomeClaw is not installed: skipped."; return 0; }
  note "On the Mac's screen, allow HomeClaw to access your home data."
  as_root launchctl kickstart "gui/$agent_uid/org.nix-community.home.homeclaw" 2>/dev/null || true
  sleep 5
  # Its HTTP MCP switch, read at launch: set, then restart it.
  app_defaults
  as_root launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.homeclaw" 2>/dev/null || true
  while [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/mcp)" = 000 ]; do
    warn "HomeClaw's MCP endpoint does not answer yet."
    note "In HomeClaw's menu bar icon → Settings → Integrations, turn on Streamable HTTP MCP."
    gum confirm --affirmative "Check again" --negative "Skip" "On?" || return 0
  done
  ok "HomeClaw serves HomeKit to Hermes"

  # Its events go to Hermes' events daemon (docs/events.md), with the secret
  # the daemon checks as a Bearer token.
  local cli=/Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli token
  token="$(as_root sed -n 's/^WEBHOOK_SECRET=//p' "$secrets")"
  if hermes_gui "$cli" config --webhook-url "http://127.0.0.1:$(setting server.hermes.events.port)" \
    --webhook-token "$token" --webhook-enabled true >/dev/null && hermes_gui "$cli" config --webhook-test >/dev/null; then
    ok "HomeClaw reports to Hermes' events"
    note "Choose what it reports: HomeClaw's menu bar icon → Settings → Webhook, turn on the doors, sensors…"
    note "(Immediate for what matters now, Batched for the rest)."
  else
    warn "Could not point HomeClaw's webhook at Hermes: Settings → Webhook, URL http://127.0.0.1:$(setting server.hermes.events.port)"
  fi
  unset token
}

homeclaw_serves() { [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/mcp || true)" != 000 ]; }
if ! on_hermes_screen; then
  warn "HomeClaw needs Hermes' desktop on the Mac's screen: it asks for it once macOS has logged it in."
elif homeclaw_serves && keep "HomeClaw serves HomeKit to Hermes"; then
  :
elif needs "HomeKit (HomeClaw)"; then
  hermes_lit 1
  homeclaw_app
  hermes_lit "$(setting server.energy.displayBrightness)"
fi
