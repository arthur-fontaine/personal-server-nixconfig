#!/usr/bin/env bash
# Sets the server up from a fresh Mac, including everything Nix cannot do:
# SSH keys, secrets, the Telegram bot, the Hermes account's login, GitHub
# access and the macOS permissions. Run it once, at the Mac's own screen (the
# permission dialogs show there), and let it reboot: nothing is left to run
# afterwards. Each step checks whether it is done first, so running it again
# from the clone (~/personal-server-nixconfig/scripts/bootstrap-macos.sh)
# only redoes what is missing, e.g. BotFather settings left for later. Name
# sections to run only those, after this host's: `bootstrap-macos.sh apple`.
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
sudo_keepalive=$!
trap 'kill $sudo_keepalive >/dev/null 2>&1 || true' EXIT

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

# ── The repository ─────────────────────────────────────────────────────────

GIT="$(nix build --no-link --print-out-paths nixpkgs#git)/bin/git"
# The repository is public and read over HTTPS: a ~/.gitconfig that rewrites
# GitHub URLs to SSH would need a key this session may not have (one in
# 1Password, over SSH).
git() { GIT_CONFIG_GLOBAL=/dev/null "$GIT" "$@"; }
if [ ! -d "$REPO_DIR/.git" ]; then
  step "Cloning $REPO_URL"
  git clone "$REPO_URL" "$REPO_DIR"
fi
ok "Repository at $REPO_DIR"
# The sections come from the clone: an old one would run old steps.
if git -C "$REPO_DIR" fetch -q origin 2>/dev/null \
  && [ "$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)" != 0 ]; then
  warn "The clone is behind GitHub: its steps are older ones."
  if gum confirm "Update it and start again?" && git -C "$REPO_DIR" pull -q --ff-only; then
    kill "$sudo_keepalive" 2>/dev/null || true
    exec "$REPO_DIR/scripts/bootstrap-macos.sh" "$@"
  fi
fi

# Each section, in order, from the clone (scripts/bootstrap/). Integrations
# come in two groups: what is set up before the configuration is applied
# (it may change it), and what needs Hermes' account, after.
sections=(host telegram models integrations system permissions apple accounts start check)
if [ "$#" -gt 0 ]; then
  for section in "$@"; do
    case "$section" in host | lib) false ;; esac && [ -e "$REPO_DIR/scripts/bootstrap/$section.sh" ] \
      || { echo "No section $section: pick among ${sections[*]:1}." >&2; exit 1; }
  done
  sections=(host "$@")
fi
source "$REPO_DIR/scripts/bootstrap/lib.sh"
for section in "${sections[@]}"; do
  source "$REPO_DIR/scripts/bootstrap/$section.sh"
done
