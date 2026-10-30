# ── This Mac: the configuration applied, Hermes' account and its access ────

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

step "The configuration"
if ! id "$agent" >/dev/null 2>&1 || [ "$host_changed" = 1 ]; then
  note "Applying it (nix-darwin): the first time, this builds and downloads a lot."
  apply
  ok "Configuration applied"
elif gum confirm --default=false "Apply the configuration again? (nothing changed above)"; then
  apply
  ok "Configuration applied"
else
  ok "Configuration unchanged"
fi
agent_uid="$(id -u "$agent")"

# The ChatGPT login made before the account existed (models.sh), moved in.
if sudo test -s "$codex_staged"; then
  if ! sudo test -s "$agent_home/.hermes/auth.json"; then
    sudo -u "$agent" mkdir -p "$agent_home/.hermes"
    sudo install -o "$agent" -g "$(id -g "$agent")" -m 600 "$codex_staged" "$agent_home/.hermes/auth.json"
  fi
  sudo rm -f "$codex_staged"
fi

# The events daemon and Hermes' webhook route share one secret.
[ -n "$(secret_value WEBHOOK_SECRET)" ] || set_secret WEBHOOK_SECRET "$(openssl rand -hex 32)"

# ── Hermes' account logs in at boot ─────────────────────────────────────────

# /etc/kcpassword holds the account's password XORed with Apple's fixed key,
# padded to a multiple of 12 bytes; macOS replays it at boot.
kc_codec() { # encode|decode, stdin → stdout
  /usr/bin/perl -e '
    my @key = (0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F);
    local $/; binmode STDIN; my $d = <STDIN>;
    $d .= "\0" x (12 - length($d) % 12) if $ARGV[0] eq "encode";
    my $p = join "", map { chr(ord(substr($d, $_, 1)) ^ $key[$_ % 11]) } 0 .. length($d) - 1;
    $p =~ s/\0.*//s if $ARGV[0] eq "decode";
    print $p;
  ' "$1"
}
# The password it replays is still the account's: a password changed since,
# or an account made again, would leave macOS asking for it at boot.
login_works() {
  sudo test -s /etc/kcpassword \
    && dscl . -authonly "$agent" "$(sudo cat /etc/kcpassword | kc_codec decode)" >/dev/null 2>&1
}

step "Hermes' login at boot"
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
elif login_works; then
  ok "macOS logs $agent in at boot"
else
  sudo test -e /etc/kcpassword && warn "The password macOS replays at boot is no longer $agent's: setting a new one."
  # A random password: nobody types it.
  password="$(openssl rand -base64 24)"
  sudo dscl . -passwd "/Users/$agent" "$password"
  printf '%s' "$password" | kc_codec encode | write_secret /etc/kcpassword
  unset password
  if login_works; then
    ok "macOS will log $agent in at boot"
  else
    warn "macOS does not take $agent's new password: it will ask for it at boot."
  fi
fi

# ── GitHub, so Hermes can push changes to this repository ──────────────────
# A fine-grained token from a pre-filled template URL, documented in
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens

step "Hermes' access to this repository (GitHub)"
# owner/repo of the remote, https or ssh.
repo_slug="$(setting server.nixconfig.remote | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
if as_agent gh auth status >/dev/null 2>&1 && keep "Hermes can push to GitHub"; then
  :
else
  note "A fine-grained token with Contents: read and write, pre-filled on this page:"
  show_link "https://github.com/settings/personal-access-tokens/new?name=Hermes%20(personal%20server)&description=Hermes%20pushes%20changes%20to%20${repo_slug//\//%2F}%20and%20applies%20them&target_name=${repo_slug%%/*}&expires_in=366&contents=write"
  note "Under Repository access, choose Only select repositories → ${repo_slug#*/} (a link cannot pick it)."
  note "Whoever can push here can change the whole Mac through sudo server-rebuild. It lasts a year:"
  note "run this script again to replace it."
  token="$(gum input --password --header "GitHub token (github_pat_…, empty to skip)" | tr -d '[:space:]')"
  if [ -n "$token" ]; then
    # In gh's own file (~/.config/gh/hosts.yml, readable by the agent only), not
    # the keychain: the agent's runs unattended, and from here it has none.
    printf '%s' "$token" | as_agent gh auth login --git-protocol https --insecure-storage --with-token
    ok "Hermes can push to GitHub"
  else
    warn "Skipped: Hermes cannot push configuration changes yet."
  fi
  unset token
fi
