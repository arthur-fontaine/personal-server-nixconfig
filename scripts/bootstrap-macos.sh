#!/usr/bin/env bash
# First-time setup of the server: Nix, this repository, then nix-darwin.
# Modelled on https://github.com/arthur-fontaine/nixconfig/blob/main/scripts/bootstrap-macos.sh,
# without Homebrew: everything here comes from Nix.
set -euo pipefail

REPO_URL="${NIXCONFIG_REPO_URL:-https://github.com/arthur-fontaine/personal-server-nixconfig.git}"
REPO_DIR="${NIXCONFIG_REPO_DIR:-$HOME/personal-server-nixconfig}"
NIX_INSTALLER_URL="https://nixos.org/nix/install"
DEFAULT_HOST="Personal-Server"

say() { printf '%b\n' "$1"; }
step() { say "\033[34m▶\033[0m \033[1m$1\033[0m"; }
ok() { say "\033[32m✓\033[0m $1"; }
die() { say "\033[31m✗\033[0m $1" >&2; exit 1; }

prompt() {
  local label="$1" default="${2:-}" value
  printf '? %s [%s]: ' "$label" "$default" >&2
  IFS= read -r value || value=''
  printf '%s' "${value:-$default}"
}

[ "$(uname -s)" = Darwin ] || die "This script only supports macOS."
[ "$(uname -m)" = arm64 ] || die "This server configuration targets Apple Silicon."
[ -t 0 ] || die "Run this from an interactive terminal."

step "Requesting administrator access"
sudo -v
while sudo -n true 2>/dev/null; do sleep 60; done &
trap 'kill $! >/dev/null 2>&1 || true' EXIT

if ! command -v nix >/dev/null 2>&1 && [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  step "Installing Nix (multi-user)"
  sh <(curl --proto '=https' --tlsv1.2 -fsSL "$NIX_INSTALLER_URL") --daemon --yes
fi
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
nix() { command nix --extra-experimental-features 'nix-command flakes' "$@"; }
ok "Nix $(nix --version)"

if [ ! -d "$REPO_DIR/.git" ]; then
  step "Cloning $REPO_URL"
  nix run nixpkgs#git -- clone "$REPO_URL" "$REPO_DIR"
fi
ok "Repository at $REPO_DIR"

host="$(prompt "Host name (a key of hosts/shared.nix, or a new one)" "$DEFAULT_HOST")"
if ! grep -q "^  $host = {" "$REPO_DIR/hosts/shared.nix" && [ ! -e "$REPO_DIR/hosts/local.nix" ]; then
  step "Writing hosts/local.nix for $host"
  cat > "$REPO_DIR/hosts/local.nix" <<EOF
{
  $host = {
    system = "aarch64-darwin";
    username = "$(id -un)";
    nixconfigDir = "$REPO_DIR";
    server = {
      ssh.authorizedKeys = [ ];
    };
  };
}
EOF
fi

step "Applying the configuration (nix-darwin)"
sudo -H env PATH="$PATH" nix --extra-experimental-features 'nix-command flakes' \
  run github:LnL7/nix-darwin#darwin-rebuild -- switch --flake "path:$REPO_DIR#$host"

ok "Done. Next: MANUAL_SETUP.md (secrets, the Hermes account, WhatsApp pairing, permissions)."
say "Later updates: sudo server-rebuild"
