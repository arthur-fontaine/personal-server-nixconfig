# ── Sideload: Xcode's Apple Account, which signs the apps ───────────────────
# xcodebuild's automatic signing (sideload, docs/sideload.md) uses the Apple
# Account signed in to Xcode on the service's account (Hermes' by default), in its login keychain: only
# Xcode's own window signs in. A free account is a Personal Team there.
# xcodes installs Xcode as Xcode-<version>.app, which open -a Xcode does not
# find: the selected Xcode, else the newest in /Applications.
xcode_app() {
  local dev app newest="" newest_version="" version
  dev="$(xcode-select -p 2>/dev/null || true)"
  case "$dev" in
    */Xcode*.app/Contents/Developer) echo "${dev%/Contents/Developer}"; return 0 ;;
  esac
  for app in /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    version="$(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0)"
    if [ -z "$newest" ] || [ "$(printf '%s\n%s\n' "$newest_version" "$version" | sort -V | tail -n 1)" = "$version" ]; then
      newest="$app" newest_version="$version"
    fi
  done
  [ -n "$newest" ] && echo "$newest"
}
# Done when sideload finds a team: Xcode 27 no longer lists it in its
# preferences, so through sideload's own lookup (lib.sh: sideload_team).
xcode_signing() { sideload_team >/dev/null; }
if [ "$(setting server.sideload.enable)" = 1 ]; then
  step "Sideload: Xcode's Apple Account"
  if ! on_hermes_screen; then
    warn "It needs Hermes' desktop on the Mac's screen: it asks once macOS has logged it in (reboot)."
  elif xcode_signing && keep "Hermes' Xcode is signed in to an Apple Account"; then
    :
  elif needs "Xcode's Apple Account" && gum confirm "Sign Hermes' Xcode in to your Apple Account, to sign the apps it sideloads?"; then
    hermes_lit 1
    if ! xcode_path="$(xcode_app)"; then
      warn "Xcode isn't installed yet: it installs with the configuration (bootstrap-macos.sh xcode, then sudo server-rebuild)."
    else
      note "On the Mac's screen, in Xcode: Xcode → Settings… → Accounts → + → Apple Account, and sign in"
      note "(a free account works: it becomes a Personal Team)."
      hermes_gui /usr/bin/open "$xcode_path" >/dev/null 2>&1 || warn "Could not open $xcode_path on Hermes' screen."
      while :; do
        gum confirm --affirmative "Check again" --negative "Skip" "Signed in?" || break
        team_check="$(sideload_team)" && break
        # Signed in without a certificate, Xcode 27 says nothing: sideload's error does.
        warn "Not yet: $team_check"
        # Brings it back if it was closed meanwhile.
        hermes_gui /usr/bin/open "$xcode_path" >/dev/null 2>&1 || true
      done
      xcode_signing && ok "Hermes' Xcode is signed in to an Apple Account"
    fi
    hermes_lit "$(setting server.energy.displayBrightness)"
  fi
fi
