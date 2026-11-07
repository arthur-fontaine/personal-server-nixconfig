# ── Sideload: Xcode's Apple Account, which signs the apps ───────────────────
# xcodebuild's automatic signing (sideload, docs/sideload.md) uses the Apple
# Account signed in to Xcode on the service's account (Hermes' by default), in its login keychain: only
# Xcode's own window signs in. A free account is a Personal Team there.
xcode_signing() { as_agent /usr/bin/defaults read com.apple.dt.Xcode 2>/dev/null | grep -q 'teamID ='; }
if [ "$(setting server.sideload.enable)" = 1 ]; then
  step "Sideload: Xcode's Apple Account"
  if ! on_hermes_screen; then
    warn "It needs Hermes' desktop on the Mac's screen: it asks once macOS has logged it in (reboot)."
  elif xcode_signing && keep "Hermes' Xcode is signed in to an Apple Account"; then
    :
  elif needs "Xcode's Apple Account" && gum confirm "Sign Hermes' Xcode in to your Apple Account, to sign the apps it sideloads?"; then
    hermes_lit 1
    while ! xcode_signing; do
      note "On the Mac's screen, in Xcode: Xcode → Settings… → Accounts → + → Apple Account, and sign in"
      note "(a free account works: it becomes a Personal Team). Xcode not there yet? It installs with the configuration."
      hermes_gui /usr/bin/open -a Xcode || true
      gum confirm --affirmative "Check again" --negative "Skip" "Signed in?" || break
    done
    xcode_signing && ok "Hermes' Xcode is signed in to an Apple Account"
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
fi
