# ── Xcode: the Apple Account xcodes downloads it with ───────────────────────
# Apple's developer downloads need an Apple Account. Its password goes to a
# root-only file of its own (server.xcode.credentialsFile), not Hermes'
# secrets file: the activation reads it (modules/system/xcode.nix), Hermes
# never does. The two-factor code is asked by that activation, in system.sh.
[ "$(setting server.xcode.enable)" = 1 ] || return 0
step "Xcode"

xcodes_env="$(setting server.xcode.credentialsFile)"
xcodes_user="$({ sudo sed -n 's/^XCODES_USERNAME=//p' "$xcodes_env" 2>/dev/null || true; } | head -n 1)"
if [ -n "$xcodes_user" ] && keep "Xcode: downloaded with $xcodes_user"; then
  return 0
fi
note "The account must have accepted the Apple Developer Agreement (sign in there once):"
show_link "https://developer.apple.com/account"
apple_id="$(gum input --header "Apple Account for Xcode's downloads (email; empty to skip Xcode)" | tr -d '[:space:]')"
if [ -n "$apple_id" ]; then
  apple_password="$(gum input --password --header "Its password")"
  printf 'XCODES_USERNAME=%s\nXCODES_PASSWORD=%s\n' "$apple_id" "$apple_password" | write_secret "$xcodes_env"
  unset apple_password
  ok "Xcode: Apple Account written; applying the configuration installs Xcode, and asks for a two-factor code the first time"
  # So system.sh applies the configuration, which installs it.
  host_changed=1
else
  warn "Xcode has no Apple Account: it is not installed."
fi
