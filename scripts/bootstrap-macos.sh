#!/usr/bin/env bash
# Sets the server up from a fresh Mac, including everything Nix cannot do:
# SSH keys, secrets, the Hermes account's login, GitHub access, WhatsApp
# pairing and the macOS permissions. Safe to run again: each step checks
# whether it is done first. Run it once, reboot when it asks, then run it again
# for the permissions, which need the Hermes session.
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
nix() { command nix --extra-experimental-features 'nix-command flakes' "$@"; }

GUM="$(nix build --no-link --print-out-paths nixpkgs#gum)/bin/gum"
gum() { "$GUM" "$@"; }
step() { gum style --bold --foreground 212 "▶ $1"; }
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

# A Nix string literal for a shell value.
nix_string() {
  local s="$1" bs='\' q='"' interp='${'
  s="${s//"$bs"/"$bs$bs"}"
  s="${s//"$q"/"$bs$q"}"
  s="${s//"$interp"/"$bs$interp"}"
  printf '"%s"' "$s"
}

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

local_nix="$REPO_DIR/hosts/local.nix"
if [ -e "$local_nix" ]; then
  HOST="$(sed -n 's/^  \([A-Za-z0-9_-]*\) = {$/\1/p' "$local_nix" | head -1)"
  ok "Host $HOST (hosts/local.nix)"
else
  step "This host"
  HOST="$(gum input --header "Host name" --value "$DEFAULT_HOST")"
  keys="$(ssh_keys)"
  if [ -z "$keys" ]; then
    warn "No SSH key: nobody will be able to log in remotely. Add one to $local_nix later."
  else
    note "$(printf '%s\n' "$keys" | wc -l | tr -d ' ') key(s) will be allowed."
  fi
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
setting() { nix eval --raw "$flake.config.$1" --apply toString; }

# Write stdin to a root-owned file that is never readable by anyone else, even briefly.
write_secret() { sudo sh -c 'umask 077 && cat > "$1"' _ "$1"; }

# ── Secrets ─────────────────────────────────────────────────────────────────

secrets="$(setting server.hermes.secretsFile)"
if sudo test -e "$secrets"; then
  ok "Secrets in $secrets"
else
  step "Secrets (stored in $secrets, readable by Hermes only)"
  opencode="$(gum input --password --header "OpenCode Zen API key (https://opencode.ai/auth)")"
  runpod="$(gum input --password --header "RunPod API key (https://www.runpod.io/console/user/settings)")"
  owner="$(gum input --header "Your WhatsApp number, country code first, digits only" --placeholder "33612345678")"
  sudo mkdir -p "$(dirname "$secrets")"
  printf 'OPENCODE_ZEN_API_KEY=%s\nRUNPOD_API_KEY=%s\nWHATSAPP_ALLOWED_USERS=%s\n' "$opencode" "$runpod" "${owner//[^0-9]/}" \
    | write_secret "$secrets"
  unset opencode runpod
  ok "Secrets written"
fi

# ── The system ──────────────────────────────────────────────────────────────

agent="$(setting server.hermes.user)"
if ! id "$agent" >/dev/null 2>&1 || gum confirm --default=false "Apply the configuration again?"; then
  step "Applying the configuration (nix-darwin)"
  if [ -x /run/current-system/sw/bin/darwin-rebuild ]; then
    sudo -H env PATH="$PATH" darwin-rebuild switch --flake "path:$REPO_DIR#$HOST"
  else
    sudo -H env PATH="$PATH" nix --extra-experimental-features 'nix-command flakes' \
      run github:LnL7/nix-darwin#darwin-rebuild -- switch --flake "path:$REPO_DIR#$HOST"
  fi
  ok "Configuration applied"
fi
agent_uid="$(id -u "$agent")"
agent_home="$(setting server.hermes.home)"
as_agent() { sudo -u "$agent" -H env PATH="/etc/profiles/per-user/$agent/bin:$PATH" "$@"; }
gui_session() { sudo launchctl print "gui/$agent_uid" >/dev/null 2>&1; }

# ── The Hermes account logs in at boot ──────────────────────────────────────

if sudo test -e /etc/kcpassword; then
  ok "$agent logs in automatically"
else
  step "Automatic login for $agent"
  if fdesetup isactive >/dev/null 2>&1; then
    warn "FileVault is on, and macOS logs nobody in automatically while it is."
    if gum confirm "Turn FileVault off? (macOS asks for an administrator's credentials)"; then
      sudo fdesetup disable
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

if as_agent gh auth status >/dev/null 2>&1; then
  ok "Hermes can push to GitHub"
else
  step "GitHub access for Hermes"
  note "A fine-grained token for this repository only, with Contents: read and write."
  note "Whoever can push here can change the whole Mac through sudo server-rebuild."
  token="$(gum input --password --header "GitHub token (empty to skip)")"
  if [ -n "$token" ]; then
    printf '%s' "$token" | as_agent gh auth login --git-protocol https --with-token
    unset token
    ok "Hermes can push to GitHub"
  else
    warn "Skipped: Hermes cannot push configuration changes yet."
  fi
fi

# ── WhatsApp ────────────────────────────────────────────────────────────────

creds="$agent_home/.hermes/platforms/whatsapp/session/creds.json"
if sudo test -e "$creds"; then
  ok "WhatsApp is paired"
else
  step "WhatsApp"
  note "Use the bot's own number. On its phone: WhatsApp → Settings → Linked Devices → Link a Device,"
  note "then scan the QR code below. Choose the bot mode."
  if gum confirm "Pair WhatsApp now?"; then
    as_agent env HERMES_HOME="$agent_home/.hermes" hermes whatsapp
    if gui_session; then
      sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.hermes-agent" || true
    fi
    ok "WhatsApp paired: message the bot from your own number"
  else
    warn "Skipped: run this script again to pair."
  fi
fi

# ── Permissions, in the Hermes session ──────────────────────────────────────

if ! gui_session; then
  step "The Hermes session"
  note "Computer use needs Accessibility and Screen Recording, granted in $agent's session,"
  note "which exists once macOS has logged it in."
  if sudo test -e /etc/kcpassword && gum confirm "Reboot now? Run this script again afterwards."; then
    sudo shutdown -r now
  fi
  warn "Run this script again once $agent is logged in, for the permissions."
  exit 0
fi

cua="$(setting home-manager.users.$agent.services.hermes-agent.environment.HERMES_CUA_DRIVER_CMD)"
brightness="$(nix build --no-link --print-out-paths "path:$REPO_DIR#display-brightness")/bin/display-brightness"
in_session() { sudo launchctl asuser "$agent_uid" sudo -u "$agent" -H env CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$@"; }

# "unknown" until Hermes has started the driver's daemon once.
permissions="$(in_session "$cua" permissions status --json 2>/dev/null | sed -n 's/.*"status": *"\([a-z_]*\)".*/\1/p')"
if [ "$permissions" != granted ] && gum confirm "Grant computer use its permissions now? (status: ${permissions:-unknown})"; then
  step "Accessibility and Screen Recording for CuaDriver"
  note "Dialogs open on this Mac's screen (lit up for now): click Allow / Open System Settings,"
  note "turn CuaDriver on in each list, then come back here."
  in_session "$brightness" 1 || true
  in_session "$cua" permissions grant || true
  gum confirm --affirmative "Done" --negative "" "Granted both in System Settings?" || true
  in_session "$brightness" "$(setting server.energy.displayBrightness)" || true
  sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.hermes-agent" || true
fi
ok "Computer use permissions checked"

if gum confirm --default=false "Should Hermes read your Desktop, Documents and Downloads? (Full Disk Access)"; then
  note "In the list that opens, add: $(as_agent sh -c 'command -v hermes')"
  note "macOS ties it to that file, so grant it again after a Hermes update."
  in_session "$brightness" 1 || true
  in_session /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
  gum confirm --affirmative "Done" --negative "" "Added?" || true
  in_session "$brightness" "$(setting server.energy.displayBrightness)" || true
fi

gum style --border rounded --padding "0 2" --foreground 42 "The server is set up." \
  "$(gum style --faint 'Message the bot on WhatsApp. Later changes: edit, push, sudo server-rebuild.')"
