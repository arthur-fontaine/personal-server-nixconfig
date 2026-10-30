#!/usr/bin/env bash
# Sets the server up from a fresh Mac, including everything Nix cannot do:
# SSH keys, secrets, the Telegram bot, the Hermes account's login, GitHub
# access and the macOS permissions. Run it once, at the Mac's own screen (the
# permission dialogs show there), and let it reboot: nothing is left to run
# afterwards. Each step checks whether it is done first, so running it again
# from the clone (~/personal-server-nixconfig/scripts/bootstrap-macos.sh)
# only redoes what is missing, e.g. BotFather settings left for later.
#
# Modelled on https://github.com/arthur-fontaine/nixconfig/blob/main/scripts/bootstrap-macos.sh,
# with gum (https://github.com/charmbracelet/gum) for the prompts and no Homebrew.
set -euo pipefail

REPO_URL="${NIXCONFIG_REPO_URL:-https://github.com/arthur-fontaine/personal-server-nixconfig.git}"
REPO_DIR="${NIXCONFIG_REPO_DIR:-$HOME/personal-server-nixconfig}"
NIX_INSTALLER_URL="https://nixos.org/nix/install"
DEFAULT_HOST="Personal-Server"

[ "$(uname -s)" = Darwin ] || { echo "This script only supports macOS." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "This server configuration targets Apple Silicon." >&2; exit 1; }
[ -t 0 ] || { echo "Run this from an interactive terminal." >&2; exit 1; }

echo "Administrator access is needed for Nix, the system and the Hermes account."
sudo -v
while sudo -n true 2>/dev/null; do sleep 60; done &
trap 'kill $! >/dev/null 2>&1 || true' EXIT

# ── Nix, then gum from it ───────────────────────────────────────────────────

if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  echo "Installing Nix (multi-user)..."
  sh <(curl --proto '=https' --tlsv1.2 -fsSL "$NIX_INSTALLER_URL") --daemon --yes
fi
export PATH="/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
# A shell opened under a previous nix-darwin still names its certificates
# (/etc/ssl/certs/ca-certificates.crt), gone with it; unset, Nix finds its own.
for var in NIX_SSL_CERT_FILE SSL_CERT_FILE; do
  if [ -n "${!var:-}" ] && [ ! -r "${!var}" ]; then unset "$var"; fi
done
nix() { command nix --extra-experimental-features 'nix-command flakes' "$@"; }

GUM="$(nix build --no-link --print-out-paths nixpkgs#gum)/bin/gum"
# gum input keeps 400 characters unless told otherwise: tokens are longer
# (a 1Password service account's is over 1000).
gum() {
  if [ "$1" = input ]; then
    shift
    "$GUM" input --char-limit 0 "$@"
  else
    "$GUM" "$@"
  fi
}
# A blank line before each section and each question that opens one, so
# unrelated questions do not run together.
step() { echo; gum style --bold --foreground 212 "▶ $1"; }
ask() { echo; gum confirm "$@"; }
ok() { gum style --foreground 42 "✓ $1"; }
note() { gum style --faint "  $1"; }
warn() { gum style --foreground 214 "! $1"; }

gum style --border rounded --padding "0 2" --bold "personal-server-nixconfig setup" \
  "$(gum style --faint 'Nix, nix-darwin and a Hermes Agent on this Mac')"

# ── The repository and this host ────────────────────────────────────────────

if [ ! -d "$REPO_DIR/.git" ]; then
  step "Cloning $REPO_URL"
  nix run nixpkgs#git -- clone "$REPO_URL" "$REPO_DIR"
fi
ok "Repository at $REPO_DIR"

# Each section, in order, from the clone (scripts/bootstrap/).
for section in host telegram models integrations system accounts permissions apple browser start check; do
  source "$REPO_DIR/scripts/bootstrap/$section.sh"
done
