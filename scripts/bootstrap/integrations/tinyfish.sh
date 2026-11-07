# TinyFish: its key, for web_search, web_fetch and view_image (modules/hermes/plugins/tinyfish).
# Checked with one search, here and on every run.
integration_on tinyfish || return 0
step "Integration · TinyFish"

tinyfish_works() {
  curl -fsS --max-time 20 -o /dev/null -H "X-API-Key: $1" "https://api.search.tinyfish.ai?query=hermes" 2>/dev/null
}
tinyfish="$(secret_value TINYFISH_API_KEY)"
if [ -n "$tinyfish" ] && tinyfish_works "$tinyfish" && keep "TinyFish: its key answers a search"; then
  unset tinyfish
  return 0
fi
[ -z "$tinyfish" ] || warn "TinyFish: the key in the secrets file does not answer a search."
show_link "https://agent.tinyfish.ai/api-keys"
while :; do
  tinyfish="$(gum input --password --header "TinyFish API key (free account; empty to skip)" | tr -d '[:space:]')"
  if [ -z "$tinyfish" ]; then
    warn "TinyFish has no key: its web tools answer with an error until one is set."
    break
  fi
  if tinyfish_works "$tinyfish"; then
    set_secret TINYFISH_API_KEY "$tinyfish"
    ok "TinyFish: key written"
    break
  fi
  warn "TinyFish refused that key (or could not be reached): try again."
done
unset tinyfish
