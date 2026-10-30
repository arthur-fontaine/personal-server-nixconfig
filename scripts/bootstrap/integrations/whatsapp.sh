# WhatsApp, as a linked device of your number (wacli, as Hermes).
integration_on whatsapp || return 0
step "Integration · WhatsApp"

wa() { as_agent env WACLI_STORE_DIR="$(setting "home-manager.users.$agent.services.hermes-agent.environment.WACLI_STORE_DIR")" wacli "$@"; }
if wa --json auth status 2>/dev/null | grep -q '"authenticated":true'; then
  keep "Hermes reads your WhatsApp" && return 0
  wa auth logout || true
fi
needs "WhatsApp" || return 0
gum confirm "Link your WhatsApp now, so Hermes can read and send your messages?" || return 0
note "On your phone: WhatsApp → Settings → Linked devices → Link a device, then scan this code."
if wa auth --idle-exit 30s; then
  ok "WhatsApp linked: its chats keep syncing in the background"
  gui_session && as_root launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.wacli" || true
else
  warn "Not linked. Run this script again to retry."
fi
