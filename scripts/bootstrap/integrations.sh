# ── Integrations: your other services, each optional ───────────────────────
# Written to hosts/local.nix (server.hermes.integrations). Each one's setup is
# its own file in integrations/: those here come before the configuration is
# applied (one may change it); WhatsApp, Instagram, Discord and HomeKit need
# Hermes' account and come after (accounts.sh). Apple's apps are always there.

# name|label (no commas: gum's --selected is comma-separated)
integration_choices=(
  "whatsapp|WhatsApp: read and send your messages and see new ones"
  "instagram|Instagram: DMs and posts and stories and its notifications"
  "discord|Discord: DMs and servers and its notifications"
  "homeassistant|Home Assistant: your devices and their changes"
  "homekit|HomeKit: your home's accessories (installs HomeClaw from the App Store)"
  "onepassword|1Password: logins Hermes fills in without seeing them"
  "runpod|RunPod: GPU pods and pods left running"
  "github|GitHub notifications as events"
)
integrations_now() {
  local line names=()
  for line in "${integration_choices[@]}"; do integration_on "${line%%|*}" && names+=("${line%%|*}"); done
  echo "${names[*]:-none}"
}

step "Integrations"
if grep -q 'integrations' "$local_nix" 2>/dev/null && keep "Integrations: $(integrations_now)"; then
  :
else
  note "Your other services Hermes may use, each acting as you there (space to pick, enter to confirm)."
  labels=() selected=()
  for line in "${integration_choices[@]}"; do
    labels+=("${line#*|}")
    integration_on "${line%%|*}" && selected+=("${line#*|}")
  done
  picked="$(IFS=,; gum choose --no-limit --selected="${selected[*]:-}" "${labels[@]}")" || picked=""
  patch="{}"
  for line in "${integration_choices[@]}"; do
    on=false
    grep -qxF "${line#*|}" <<< "$picked" && on=true
    patch="$("$JQ" -c --arg n "${line%%|*}" --argjson on "$on" '.[$n] = {enable: $on}' <<< "$patch")"
  done
  set_host "$("$JQ" -cn --argjson i "$patch" '{server: {hermes: {integrations: $i}}}')"
  ok "Integrations: $(integrations_now)"
fi

for integration in runpod homeassistant onepassword github; do
  source "$REPO_DIR/scripts/bootstrap/integrations/$integration.sh"
done
