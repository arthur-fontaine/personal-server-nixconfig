# ── Permissions ─────────────────────────────────────────────────────────────
# Accessibility, Screen Recording and Full Disk Access live in macOS' system
# database, so granting them from this session covers the Hermes account too.
# The dialogs need a screen: this session's if it has one, else Hermes'.

cua="$(setting home-manager.users.$agent.services.hermes-agent.environment.HERMES_CUA_DRIVER_CMD)"
launcher="$(setting server.hermes.access.launcher)"
if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  in_gui() { env CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$@"; }
  lit() { :; }
elif gui_session; then
  in_gui() { sudo launchctl asuser "$agent_uid" sudo -u "$agent" -H env CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$@"; }
  # Hermes' session keeps the backlight off: light it while you click.
  brightness="$(nix build --no-link --print-out-paths "path:$REPO_DIR#display-brightness")/bin/display-brightness"
  lit() { in_gui "$brightness" "$1" || true; }
else
  in_gui() { return 1; }
  lit() { :; }
fi

step "Permissions: computer use and Full Disk Access"
if in_gui true; then
  # "unknown" until the driver's daemon has run once.
  permissions="$(in_gui "$cua" permissions status --json 2>/dev/null | sed -n 's/.*"status": *"\([a-z_]*\)".*/\1/p')"
  if [ "$permissions" != granted ] && gum confirm "Grant computer use its permissions now? (status: ${permissions:-unknown})"; then
    note "Accessibility and Screen Recording for CuaDriver."
    note "Dialogs open on this Mac's screen: click Allow / Open System Settings,"
    note "turn CuaDriver on in each list, then come back here."
    lit 1
    in_gui "$cua" permissions grant || true
    gum confirm --affirmative "Done" --negative "" "Granted both?" || true
    lit "$(setting server.energy.displayBrightness)"
  fi

  if ask "Give Hermes Full Disk Access? (to read Desktop, Documents, Downloads, Mail, iCloud...)"; then
    note "Full Disk Access for $launcher."
    note "In the list that opens, click +, then drag in the file Finder shows (or ⇧⌘G and paste its path)."
    note "It is granted once: Hermes updates keep it."
    lit 1
    in_gui /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    in_gui /usr/bin/open -R "$launcher"
    gum confirm --affirmative "Done" --negative "" "Added?" || true
    lit "$(setting server.energy.displayBrightness)"
  fi
  ok "Permissions handled"
else
  warn "No screen here (SSH?): run this script at the Mac itself to grant the permissions."
fi
