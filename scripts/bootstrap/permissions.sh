# ── Permissions ─────────────────────────────────────────────────────────────
# Accessibility, Screen Recording and Full Disk Access live in macOS' system
# database, so granting them from this session covers the Hermes account too.
# The dialogs need a screen: this session's if it has one, else Hermes'.

cua="$(setting home-manager.users.$agent.services.hermes-agent.environment.HERMES_CUA_DRIVER_CMD)"
if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  in_gui() { env CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$@"; }
  lit() { :; }
elif gui_session; then
  in_gui() { hermes_gui env CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$@"; }
  lit() { hermes_lit "$1"; }
else
  in_gui() { return 1; }
  lit() { :; }
fi

step "Permissions: computer use and Full Disk Access"
if in_gui true; then
  # "unknown" until the driver's daemon has run once.
  permissions="$(in_gui "$cua" permissions status --json 2>/dev/null | sed -n 's/.*"status": *"\([a-z_]*\)".*/\1/p')"
  if [ "$permissions" = granted ]; then
    ok "Computer use has Accessibility and Screen Recording"
  elif needs "computer use's permissions" \
    && gum confirm "Grant computer use its permissions now? (status: ${permissions:-unknown})"; then
    note "Accessibility and Screen Recording for CuaDriver."
    note "Dialogs open on this Mac's screen: click Allow / Open System Settings,"
    note "turn CuaDriver on in each list, then come back here."
    lit 1
    in_gui "$cua" permissions grant || true
    gum confirm --affirmative "Done" --negative "" "Granted both?" || true
    lit "$(setting server.energy.displayBrightness)"
  fi

  if full_disk_access; then
    ok "Hermes has Full Disk Access"
  elif needs "Full Disk Access" \
    && ask "Give Hermes Full Disk Access? (to read Desktop, Documents, Downloads, Mail, iCloud...)"; then
    note "Full Disk Access for $launcher."
    note "In the list that opens, click +, then drag in the file Finder shows (or ⇧⌘G and paste its path)."
    note "It is granted once: Hermes updates keep it."
    lit 1
    in_gui /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    in_gui /usr/bin/open -R "$launcher"
    gum confirm --affirmative "Done" --negative "" "Added?" || true
    lit "$(setting server.energy.displayBrightness)"
  fi

  # Finding iMCP over Bonjour, Hermes' tools ask macOS (Local Network) once,
  # and nothing tells whether that was answered: ask now, while you look.
  if [ -z "${checking:-}" ] && gui_session; then
    note "If the Mac asks whether hermes-launcher may find devices on your local network: Allow."
    as_gateway '/usr/bin/dns-sd -B _imcp._tcp local. >/dev/null & sleep 5; kill $!' >/dev/null 2>&1 || true
  fi
else
  warn "No screen here: Hermes' screen asks for them once macOS has logged it in (reboot)."
fi
