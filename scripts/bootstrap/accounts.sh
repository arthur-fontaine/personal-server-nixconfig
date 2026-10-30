# ── Integrations on Hermes' account ─────────────────────────────────────────
# Those that need Hermes' account (WhatsApp) or its desktop on the Mac's
# screen (Instagram, Discord, HomeKit, which also needs its Apple Account,
# apple.sh). Each one's setup is its own file in integrations/.

for integration in whatsapp instagram discord homekit; do
  source "$REPO_DIR/scripts/bootstrap/integrations/$integration.sh"
done
