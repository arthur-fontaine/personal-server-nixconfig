# ── This host: its name and the SSH keys that may log in ────────────────────
# Written to the git-ignored hosts/local.nix, which every later choice
# extends.

ssh_keys() {
  local source keys="" user
  source="$(gum choose --header "Which public keys may log in over SSH?" \
    "My GitHub account's keys" "Paste them" "This Mac's ~/.ssh/*.pub")"
  case "$source" in
    "My GitHub account's keys")
      user="$(gum input --header "GitHub user name" --placeholder "arthur-fontaine")"
      keys="$(curl -fsSL "https://github.com/$user.keys")"
      ;;
    "Paste them")
      keys="$(gum write --header "One public key per line" --placeholder "ssh-ed25519 AAAA... laptop")"
      ;;
    *)
      keys="$(cat "$HOME"/.ssh/*.pub 2>/dev/null || true)"
      ;;
  esac
  printf '%s\n' "$keys" | grep -E '^(ssh-|ecdsa-|sk-)' || true
}
count_keys() {
  if [ -z "$1" ]; then
    warn "No SSH key: nobody will be able to log in remotely."
  else
    note "$(printf '%s\n' "$1" | wc -l | tr -d ' ') key(s) will be allowed."
  fi
}

step "This host"
local_nix="$REPO_DIR/hosts/local.nix"
if [ -e "$local_nix" ]; then
  HOST="$(sed -n 's/^  \([A-Za-z0-9_-]*\) = {$/\1/p' "$local_nix" | head -1)"
  flake="path:$REPO_DIR#darwinConfigurations.$HOST"
  if ! keep "Host $HOST, $(nix eval --json "$flake.config.server.ssh.authorizedKeys" | "$JQ" length) SSH key(s) (hosts/local.nix)"; then
    keys="$(ssh_keys)"
    count_keys "$keys"
    set_host "$("$JQ" -cn --arg k "$keys" '{server: {ssh: {authorizedKeys: ($k | split("\n") | map(select(. != "")))}}}')"
    ok "SSH keys written: applied with the configuration"
  fi
else
  HOST="$(gum input --header "Host name" --value "$DEFAULT_HOST")"
  keys="$(ssh_keys)"
  count_keys "$keys"
  {
    echo "# This Mac's host, written by scripts/bootstrap-macos.sh. Git-ignored."
    echo "{"
    echo "  $HOST = {"
    echo "    system = \"aarch64-darwin\";"
    echo "    username = $(nix_string "$(id -un)");"
    echo "    nixconfigDir = $(nix_string "$REPO_DIR");"
    echo "    server.ssh.authorizedKeys = ["
    while IFS= read -r key; do
      [ -n "$key" ] && echo "      $(nix_string "$key")"
    done <<< "$keys"
    echo "    ];"
    echo "  };"
    echo "}"
  } > "$local_nix"
  ok "Wrote hosts/local.nix"
fi

flake="path:$REPO_DIR#darwinConfigurations.$HOST"
secrets="$(setting server.hermes.secretsFile)"
agent="$(setting server.hermes.user)"
agent_home="$(setting server.hermes.home)"
agent_uid="$(id -u "$agent" 2>/dev/null || true)" # once the account exists (system.sh)
launcher="$(setting server.hermes.access.launcher)"
gateway_path="$(setting "home-manager.users.$agent.launchd.agents.hermes-agent.config.EnvironmentVariables.PATH")"
