#!/usr/bin/env bash
# Disables, removes or fully uninstalls the server, from its clone:
#
#   ~/personal-server-nixconfig/scripts/uninstall-macos.sh
#
# - disable: Hermes stops (server.hermes.enable = false); its account and
#   memory stay, and enabling it again brings it back as it was;
# - enable: the reverse, then the setup script recreates its auto-login;
# - remove Hermes: disable, then delete its account, memory and grants;
# - remove everything: also uninstall nix-darwin and Nix, and put macOS'
#   own settings back.
#
# docs/uninstall.md describes each step, to do them by hand.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
nix() { command nix --extra-experimental-features 'nix-command flakes' "$@"; }

[ -t 0 ] || { echo "Run this from an interactive terminal." >&2; exit 1; }
command -v nix >/dev/null || { echo "Nix is not installed: nothing of this server is left." >&2; exit 1; }
sudo -v

GUM="$(nix build --no-link --print-out-paths nixpkgs#gum)/bin/gum"
gum() { "$GUM" "$@"; }
step() { gum style --bold --foreground 212 "▶ $1"; }
ok() { gum style --foreground 42 "✓ $1"; }
warn() { gum style --foreground 214 "! $1"; }

local_nix="$REPO_DIR/hosts/local.nix"
if [ -e "$local_nix" ]; then
  HOST="$(sed -n 's/^  \([A-Za-z0-9_-]*\) = {$/\1/p' "$local_nix" | head -1)"
fi
HOST="$(gum input --header "Host" --value "${HOST:-Personal-Server}")"
flake="path:$REPO_DIR#darwinConfigurations.$HOST"
setting() { nix eval --raw "$flake.config.$1" --apply toString; }

agent="$(setting server.hermes.user)"
agent_home="$(setting server.hermes.home)"
admin_home="$(setting server.admin.home)"
secrets="$(setting server.hermes.secretsFile)"
launcher="$(setting server.hermes.access.launcher)"

switch() {
  step "Applying the configuration"
  sudo -H env PATH="$PATH" darwin-rebuild switch --flake "path:$REPO_DIR#$HOST"
}

# hosts/local.nix again, with server.hermes.enable changed (scripts/lib/set-host.nix).
set_hermes() {
  local text
  text="$(REPO="$REPO_DIR" HOST="$HOST" PATCH="{\"server\":{\"hermes\":{\"enable\":$1}}}" \
    nix eval --impure --raw --file "$REPO_DIR/scripts/lib/set-host.nix")"
  printf '%s' "$text" > "$local_nix"
  ok "hosts/local.nix: server.hermes.enable = $1"
}

# What the configuration no longer manages once Hermes is off: the agents in
# its session, and the auto-login.
stop_session() {
  local uid
  uid="$(id -u "$agent" 2>/dev/null)" || return 0
  for plist in "$agent_home"/Library/LaunchAgents/org.nix-community.home.*.plist; do
    sudo test -e "$plist" || continue
    sudo launchctl bootout "gui/$uid/$(basename "$plist" .plist)" 2>/dev/null || true
    sudo rm -f "$plist"
  done
  sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true
  sudo rm -f /etc/kcpassword
  if sudo launchctl print "gui/$uid" >/dev/null 2>&1 && gum confirm "Log $agent out now?"; then
    sudo launchctl bootout "gui/$uid" || true
  fi
  ok "Nothing of Hermes runs, and macOS no longer logs $agent in"
}

disable() {
  set_hermes false
  switch
  stop_session
}

remove_hermes() {
  disable
  step "Removing Hermes' account, memory and grants"
  # Before the account goes: ACL entries name it. Removing an entry by its text
  # also removes the copies files inherited, and leaves other entries alone.
  sudo chmod -R -a "user:$agent allow read,execute,readattr,readextattr,readsecurity,file_inherit,directory_inherit" "$admin_home" 2>/dev/null || true
  for root in "$admin_home" /Users/Shared /private/tmp /private/var/tmp; do
    sudo chmod -R -a "user:$agent deny write,delete,append,writeattr,writeextattr,writesecurity,chown" "$root" 2>/dev/null || true
    sudo chmod -R -a "user:$agent deny delete,writeattr,writeextattr,writesecurity,chown" "$root" 2>/dev/null || true
    sudo chmod -R -a "user:$agent allow list,search,add_file,add_subdirectory,delete_child,readattr,readextattr,readsecurity" "$root" 2>/dev/null || true
  done
  if id "$agent" >/dev/null 2>&1; then
    sudo sysadminctl -deleteUser "$agent" 2>/dev/null || sudo dscl . -delete "/Users/$agent"
  fi
  sudo dscl . -delete "/Groups/$agent" 2>/dev/null || true
  sudo rm -rf "$agent_home" "$(dirname "$secrets")" "$(dirname "$launcher")" \
    /var/db/hermes-freeze /var/db/hermes-read-acl /var/log/hermes-freeze.log
  ok "Hermes is gone. The files it made that froze stay yours."
  warn "Revoke its GitHub token and its API keys (OpenCode Zen, RunPod) where you created them,"
  warn "and its Telegram bot: send @BotFather /revoke (new token) or /deletebot."
}

remove_everything() {
  gum style --foreground 196 --bold "This uninstalls Hermes, nix-darwin and Nix, and deletes /nix."
  [ "$(gum input --header "Type the host name ($HOST) to go on")" = "$HOST" ] || { warn "Stopped."; exit 1; }
  remove_hermes

  step "Putting macOS' own settings back"
  sudo pmset -a restoredefaults || true
  sudo mdutil -a -i on >/dev/null || true
  if command -v blueutil >/dev/null; then blueutil --power 1 || true; fi
  sudo nvram -d StartupMute 2>/dev/null || true

  step "Uninstalling nix-darwin"
  sudo -H env PATH="$PATH" nix --extra-experimental-features 'nix-command flakes' run nix-darwin#darwin-uninstaller

  # The Nix manual's steps for macOS:
  # https://github.com/NixOS/nix/blob/master/doc/manual/source/installation/uninstall.md
  step "Uninstalling Nix"
  for rc in /etc/zshrc /etc/bashrc /etc/bash.bashrc; do
    if [ -e "$rc.backup-before-nix" ]; then sudo mv "$rc.backup-before-nix" "$rc"; fi
  done
  for daemon in org.nixos.nix-daemon org.nixos.darwin-store; do
    if [ -e "/Library/LaunchDaemons/$daemon.plist" ]; then
      sudo launchctl unload "/Library/LaunchDaemons/$daemon.plist" || true
      sudo rm -f "/Library/LaunchDaemons/$daemon.plist"
    fi
  done
  sudo dscl . -delete /Groups/nixbld 2>/dev/null || true
  for user in $(dscl . -list /Users | grep '^_nixbld'); do sudo dscl . -delete "/Users/$user"; done
  sudo sed -i '' '\| /nix apfs |d' /etc/fstab 2>/dev/null || true
  if [ -f /etc/synthetic.conf ]; then
    sudo sed -i '' '/^nix$/d' /etc/synthetic.conf
    [ -s /etc/synthetic.conf ] || sudo rm -f /etc/synthetic.conf
  fi
  sudo rm -rf /etc/nix /var/root/.nix-profile /var/root/.nix-defexpr /var/root/.nix-channels \
    "$HOME/.nix-profile" "$HOME/.nix-defexpr" "$HOME/.nix-channels"
  if sudo diskutil apfs deleteVolume /nix; then
    ok "Nix is gone"
  else
    warn "The /nix volume is in use: reboot, then run: sudo diskutil apfs deleteVolume /nix"
  fi
  echo "This repository's clone is still at $REPO_DIR; delete it when you are done."
}

choice="$(gum choose --header "What should happen to this server?" \
  "Disable Hermes (keep its account and memory)" \
  "Enable Hermes again" \
  "Remove Hermes (delete its account and memory)" \
  "Remove everything (Hermes, nix-darwin, Nix)")"

case "$choice" in
  Disable*) disable ;;
  Enable*)
    set_hermes true
    switch
    ok "Hermes is back. The setup script recreates its auto-login:"
    exec "$REPO_DIR/scripts/bootstrap-macos.sh"
    ;;
  "Remove Hermes"*) gum confirm "Delete $agent's account and memory for good?" && remove_hermes ;;
  "Remove everything"*) remove_everything ;;
esac
