# Sourced by scripts/bootstrap-macos.sh, in its order.
# ── 1Password, for the logins Hermes may use ───────────────────────────────
# A service account that reads one vault: browser_vault fills its logins into
# web pages (Instagram) without the model seeing them.

op_vault="$(setting server.hermes.onepassword.vault)"
if ! integration_on onepassword; then
  :
elif sudo grep -q '^OP_SERVICE_ACCOUNT_TOKEN=' "$secrets"; then
  ok "Hermes reads 1Password's \"$op_vault\" vault"
else
  step "1Password for Hermes"
  note "In 1Password: create a vault named \"$op_vault\", then Developer → Service Accounts → New,"
  note "with read access to \"$op_vault\" only. Put there the logins Hermes may use."
  op_token="$(gum input --password --header "Service account token (ops_…, empty to skip)" | tr -d '[:space:]')"
  if [ -n "$op_token" ]; then
    op="$(nix build --no-link --print-out-paths "$flake.pkgs._1password-cli")/bin/op"
    if OP_SERVICE_ACCOUNT_TOKEN="$op_token" "$op" vault list --format json 2>/dev/null \
      | "$JQ" -e --arg v "$op_vault" 'any(.[]; .name == $v)' >/dev/null; then
      printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$op_token" | sudo sh -c 'umask 077 && cat >> "$1"' _ "$secrets"
      ok "Hermes reads 1Password's \"$op_vault\" vault"
    else
      warn "That token cannot read a vault named \"$op_vault\": skipped. Run this script again to retry."
    fi
    unset op_token
  fi
fi

# ── WhatsApp, as a linked device of your number ────────────────────────────

wa() { as_agent env WACLI_STORE_DIR="$(setting "home-manager.users.$agent.services.hermes-agent.environment.WACLI_STORE_DIR")" wacli "$@"; }
if ! integration_on whatsapp; then
  :
elif wa --json auth status 2>/dev/null | grep -q '"authenticated":true'; then
  ok "Hermes reads your WhatsApp"
elif ask "Link your WhatsApp, so Hermes can read and send your messages?"; then
  step "WhatsApp"
  note "On your phone: WhatsApp → Settings → Linked devices → Link a device, then scan this code."
  if wa auth --idle-exit 30s; then
    ok "WhatsApp linked: its chats keep syncing in the background"
    gui_session && sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.wacli" || true
  else
    warn "Not linked. Run this script again to retry."
  fi
fi
