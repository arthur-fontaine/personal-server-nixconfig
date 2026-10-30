# ── Start ───────────────────────────────────────────────────────────────────

step "Start"
if gui_session; then
  sudo launchctl kickstart -k "gui/$agent_uid/org.nix-community.home.hermes-agent" || true
  ok "Hermes is running"
elif sudo test -e /etc/kcpassword && gum confirm "Reboot now? macOS then logs Hermes in and starts it."; then
  sudo shutdown -r now
else
  warn "Hermes starts once macOS logs $agent in: reboot when you are ready."
fi
