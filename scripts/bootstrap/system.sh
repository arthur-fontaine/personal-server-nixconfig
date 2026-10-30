# Sourced by scripts/bootstrap-macos.sh, in its order.
# ── The system ──────────────────────────────────────────────────────────────

switch_system() {
  if [ -x /run/current-system/sw/bin/darwin-rebuild ]; then
    sudo -H env PATH="$PATH" darwin-rebuild switch --flake "path:$REPO_DIR#$HOST"
  else
    sudo -H env PATH="$PATH" nix --extra-experimental-features 'nix-command flakes' \
      run github:LnL7/nix-darwin#darwin-rebuild -- switch --flake "path:$REPO_DIR#$HOST"
  fi
}

# nix-darwin will not overwrite an /etc file it does not recognise (often
# /etc/shells on a first switch): it lists them and asks to rename them
# <file>.before-nix-darwin. Do that, with your go-ahead, and switch again.
apply() {
  local log files
  log="$(mktemp)"
  if switch_system 2>&1 | tee "$log"; then
    rm -f "$log"
    return 0
  fi
  files="$(sed -n '/would be overwritten:/,/^Please check/p' "$log" | sed -n 's|^[[:space:]]*\(/etc/[^[:space:]]*\)$|\1|p')"
  rm -f "$log"
  [ -n "$files" ] || return 1
  warn "nix-darwin wants to manage these files, which macOS or an installer already wrote:"
  printf '  %s\n' $files
  gum confirm "Rename them to <file>.before-nix-darwin and apply again?" || return 1
  for file in $files; do
    sudo mv "$file" "$file.before-nix-darwin"
  done
  switch_system
}

agent="$(setting server.hermes.user)"
if ! id "$agent" >/dev/null 2>&1 || ask --default=false "Apply the configuration again?"; then
  step "Applying the configuration (nix-darwin)"
  apply
  ok "Configuration applied"
fi
agent_uid="$(id -u "$agent")"
as_agent() { sudo -u "$agent" -H env PATH="/etc/profiles/per-user/$agent/bin:$PATH" "$@"; }
gui_session() { sudo launchctl print "gui/$agent_uid" >/dev/null 2>&1; }

# ── The Hermes account logs in at boot ──────────────────────────────────────

if sudo test -e /etc/kcpassword; then
  ok "$agent logs in automatically"
else
  step "Automatic login for $agent"
  if fdesetup isactive >/dev/null 2>&1; then
    warn "FileVault is on, and macOS logs nobody in automatically while it is."
    if gum confirm "Turn FileVault off? (macOS asks for your password, the one that unlocks the disk)"; then
      # FileVault releases the disk's key only for a user allowed to unlock it,
      # whatever sudo says: the password cannot be skipped, the user name can.
      sudo fdesetup disable -user "$(id -un)"
    fi
  fi
  if fdesetup isactive >/dev/null 2>&1; then
    warn "Skipped: computer use and uzu need $agent logged in. Run this script again once FileVault is off."
  else
    # A random password: nobody types it, macOS replays it at boot from
    # /etc/kcpassword (the password XORed with Apple's fixed key, padded to 12 bytes).
    password="$(openssl rand -base64 24)"
    sudo dscl . -passwd "/Users/$agent" "$password"
    /usr/bin/perl -e '
      my @key = (0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F);
      my $p = shift; $p .= "\0" x (12 - length($p) % 12);
      print join "", map { chr(ord(substr($p, $_, 1)) ^ $key[$_ % 11]) } 0 .. length($p) - 1;
    ' "$password" | write_secret /etc/kcpassword
    unset password
    ok "$agent will log in at boot"
  fi
fi

# ── GitHub, so Hermes can push changes to this repository ──────────────────
# Both tokens from pre-filled pages: a fine-grained template URL (documented in
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
# and the classic form's scopes parameter.

# owner/repo of the remote, https or ssh.
repo_slug="$(setting server.nixconfig.remote | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"

# Opened in a browser when this session has a screen, always printed.
show_link() {
  note "$1"
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 && /usr/bin/open "$1" 2>/dev/null || true
}

if as_agent gh auth status >/dev/null 2>&1; then
  ok "Hermes can push to GitHub"
else
  step "GitHub access for Hermes"
  note "A fine-grained token with Contents: read and write, pre-filled on this page:"
  show_link "https://github.com/settings/personal-access-tokens/new?name=Hermes%20(personal%20server)&description=Hermes%20pushes%20changes%20to%20${repo_slug//\//%2F}%20and%20applies%20them&target_name=${repo_slug%%/*}&expires_in=366&contents=write"
  note "Under Repository access, choose Only select repositories → ${repo_slug#*/} (a link cannot pick it)."
  note "Whoever can push here can change the whole Mac through sudo server-rebuild. It lasts a year:"
  note "run this script again to replace it."
  token="$(gum input --password --header "GitHub token (github_pat_…, empty to skip)")"
  if [ -n "$token" ]; then
    # In gh's own file (~/.config/gh/hosts.yml, readable by the agent only), not
    # the keychain: the agent's runs unattended, and from here it has none.
    printf '%s' "$token" | as_agent gh auth login --git-protocol https --insecure-storage --with-token
    unset token
    ok "Hermes can push to GitHub"
  else
    warn "Skipped: Hermes cannot push configuration changes yet."
  fi
fi

# Notifications, for Hermes' events (docs/events.md): fine-grained tokens
# cannot read them, so a classic token with that one scope, kept apart.
if sudo grep -q '^GITHUB_NOTIFICATIONS_TOKEN=' "$secrets"; then
  ok "Hermes reads your GitHub notifications"
elif [ "$(setting server.hermes.events.github)" = 1 ]; then
  step "GitHub notifications, as Hermes' events (optional)"
  note "A classic token with only the notifications scope, pre-filled on this page:"
  show_link "https://github.com/settings/tokens/new?description=Hermes%20notifications%20(personal%20server)&scopes=notifications"
  token="$(gum input --password --header "Notifications token (ghp_…, empty to skip)")"
  if [ -n "$token" ]; then
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" https://api.github.com/notifications)" = 200 ]; then
      printf 'GITHUB_NOTIFICATIONS_TOKEN=%s\n' "$token" | sudo sh -c 'umask 077 && cat >> "$1"' _ "$secrets"
      ok "Hermes reads your GitHub notifications"
    else
      warn "GitHub refused that token for notifications: skipped. Run this script again to retry."
    fi
    unset token
  fi
fi

# ── Your ChatGPT subscription, when the chain uses it ──────────────────────

uses_codex="$(nix eval --json "$flake.config.server.hermes" --apply 'h: builtins.any (p: p == "openai-codex") ([h.model.provider] ++ map (f: f.provider) h.fallbacks)')"
if [ "$uses_codex" = true ]; then
  hermes_cli() {
    as_agent env HERMES_HOME="$(setting server.hermes.home)/.hermes" \
      "$(setting "home-manager.users.$agent.services.hermes-agent.package")/bin/hermes" "$@"
  }
  if ! hermes_cli auth status openai-codex 2>&1 | grep -q "logged out"; then
    ok "Hermes is logged in to your ChatGPT subscription"
  else
    step "Your ChatGPT subscription"
    note "Hermes logs in with a code: open the link it shows (on any device), sign in to ChatGPT, enter the code."
    if hermes_cli auth add openai-codex --type oauth; then
      ok "Hermes is logged in to your ChatGPT subscription"
    else
      warn "Not logged in: Hermes falls back to the next model. Run this script again to retry."
    fi
  fi
fi

# ── Events: the daemon and Hermes' webhook route share one secret ──────────

if ! sudo grep -q '^WEBHOOK_SECRET=' "$secrets"; then
  printf 'WEBHOOK_SECRET=%s\n' "$(openssl rand -hex 32)" | sudo sh -c 'umask 077 && cat >> "$1"' _ "$secrets"
  ok "Secret for Hermes' events written"
fi
