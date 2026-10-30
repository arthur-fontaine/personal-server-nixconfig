# RunPod: its key, for its MCP server and its events.
integration_on runpod || return 0
step "Integration · RunPod"

if [ -n "$(secret_value RUNPOD_API_KEY)" ] && keep "RunPod: its key is in the secrets file"; then
  return 0
fi
runpod="$(gum input --password --header "RunPod API key (https://www.runpod.io/console/user/settings; empty to skip)" | tr -d '[:space:]')"
if [ -n "$runpod" ]; then
  set_secret RUNPOD_API_KEY "$runpod"
  ok "RunPod: key written"
else
  warn "RunPod has no key: its tools and events stay off."
fi
unset runpod
