# ── Models: the main one, then its fallbacks ────────────────────────────────
# Hermes tries them in order when one fails (a limit reached, an outage), for
# that turn; the local model (uzu) always comes last. Written to
# hosts/local.nix (server.hermes.model, .fallbacks, and .providers for other
# OpenAI-compatible APIs); each key goes to the secrets file as soon as its
# provider is chosen. The providers and models are Hermes' own lists. A
# ChatGPT subscription logs in here too, before Hermes' account exists if need
# be (system.sh then hands the login over).

step "Models"
note "Getting Hermes' lists of providers and models (Hermes is built first: a while, the first time)..."
HERMES_PY="$(nix build --no-link --print-out-paths \
  "$flake.config.home-manager.users.$agent.services.hermes-agent.package.hermesVenv")/bin/python3"
hermes_models() { "$HERMES_PY" -I "$REPO_DIR/scripts/lib/hermes-models.py" "$@"; }
provider_rows="$(hermes_models providers)" # id<TAB>label<TAB>key variable
provider_names="$(hermes_models names)"
provider_field() { awk -F'\t' -v id="$1" -v f="$2" '$1 == id { print $f; exit }' <<< "$provider_rows"; }

key_page() {
  case "$1" in
    opencode-zen | opencode-go) echo "https://opencode.ai/auth" ;;
    openrouter) echo "https://openrouter.ai/settings/keys" ;;
    anthropic) echo "https://console.anthropic.com/settings/keys" ;;
    openai-api) echo "https://platform.openai.com/api-keys" ;;
    deepseek) echo "https://platform.deepseek.com/api_keys" ;;
    gemini) echo "https://aistudio.google.com/apikey" ;;
    xai) echo "https://console.x.ai" ;;
  esac
}
ask_key() { # provider label variable: its key, unless the secrets file has it
  local value page
  [ -n "$3" ] || return 0
  if [ -n "$(secret_value "$3")" ]; then
    ok "$2: its key is in the secrets file"
    return 0
  fi
  page="$(key_page "$1")"
  value="$(gum input --password --header "$2 API key ($3${page:+, from $page}; empty to skip)" | tr -d '[:space:]')"
  if [ -n "$value" ]; then
    set_secret "$3" "$value"
    ok "$2: key written"
  else
    warn "$2 has no key: Hermes skips it in the chain."
  fi
}

# What a provider is best used with; otherwise its list's own order.
preferred_model() {
  case "$1" in
    openai-codex) echo "gpt-6-luna" ;; # every ChatGPT plan's default
  esac
}

# The model, from the provider's list ($3) or typed in. Sets pick_model.
choose_model() { # provider label models
  local other="Another model: type its id" first choice
  first="$(preferred_model "$1")"
  choice="$( {
    if [ -n "$first" ] && grep -qxF "$first" <<< "$3"; then echo "$first"; fi
    grep -vxF -e "$first" -e "" <<< "$3" || true
    echo "$other"
  } | gum filter --no-strict --height 15 --header "$2 · model" --placeholder "Type to search, or a model id")"
  [ "$choice" = "$other" ] && choice="$(gum input --header "$2 · model id")"
  pick_model="$choice"
  [ -n "$pick_model" ]
}

# Another OpenAI-compatible API ($1: its name, if typed already): its address
# and key, checked on its /models, which also lists its models. Sets
# pick_provider, pick_label and pick_model, and adds it to new_providers.
custom_api() {
  local name="${1:-}" slug var url key response status models auth
  [ -n "$name" ] || name="$(gum input --header "Its name (e.g. Mistral)")"
  [ -n "$name" ] || return 1
  slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
  # Not a name Hermes gives a provider of its own, nor the local model's.
  while [ "$slug" = uzu ] || grep -qxF "$slug" <<< "$provider_names"; do slug="$slug-custom"; done
  var="$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')_API_KEY"
  url="$("$JQ" -r --arg s "$slug" '.[$s].url // empty' <<< "$new_providers")"
  key="$(secret_value "$var")"
  while :; do
    url="$(gum input --value "$url" --header "$name's address, the one /models and /chat/completions hang from" \
      --placeholder "https://api.example.com/v1")"
    url="${url%/}"
    [ -n "$url" ] || return 1
    [ -n "$key" ] || key="$(gum input --password --header "$name API key ($var; empty if it takes none)" | tr -d '[:space:]')"
    auth=()
    [ -n "$key" ] && auth=(-H "Authorization: Bearer $key")
    response="$(curl -s -w '\n%{http_code}' --max-time 15 ${auth[@]+"${auth[@]}"} "$url/models" || true)"
    status="${response##*$'\n'}"
    models="$("$JQ" -r '.data[]?.id // empty' <<< "${response%$'\n'*}" 2>/dev/null || true)"
    case "$status" in
      2??) [ -n "$models" ] && ok "$name answers, with $(wc -l <<< "$models" | tr -d ' ') models" && break
        warn "$name answers, but lists no models: you will type the model's id." && break ;;
      401 | 403) warn "$name refused that key (status $status)."; key="" ;;
      000) warn "Nothing answers at $url from this Mac: a wrong address, another network, or the local network not allowed." ;;
      *) warn "$url/models answers $status: not an OpenAI-compatible address?" ;;
    esac
    gum confirm --affirmative "Try again" --negative "Skip" "Retry?" || return 1
  done
  [ -n "$key" ] && set_secret "$var" "$key"
  new_providers="$("$JQ" -c --arg s "$slug" --arg l "$name" --arg u "$url" --arg k "$var" --argjson keyed "$([ -n "$key" ] && echo true || echo false)" \
    '.[$s] = {label: $l, url: $u, keyEnv: (if $keyed then $k else null end)}' <<< "$new_providers")"
  pick_provider="$slug" pick_label="$name"
  choose_model "$slug" "$name" "$models"
}

# One model of the chain: its provider (and key), then the model. Sets
# pick_provider, pick_label, pick_model; pick_provider empty when $2 offers
# to stop and that is chosen. Returns 1 when abandoned, to ask again.
choose_entry() { # header [stop label]
  local custom="Another OpenAI-compatible API (its address)" rows choice id var envs=() models
  pick_provider="" pick_label="" pick_model=""
  rows="$(awk -F'\t' '{ print $2 " · " $1 }' <<< "$provider_rows")"
  choice="$( {
    if [ -n "${2:-}" ]; then echo "$2"; fi
    echo "$rows"
    echo "$custom"
  } | gum filter --no-strict --height 15 --header "$1" --placeholder "Type to search, or the name of another API")"
  [ -n "$choice" ] || return 1
  [ "$choice" = "${2:-}" ] && return 0
  if grep -qxF "$choice" <<< "$rows"; then
    id="${choice##* · }"
  elif [ -n "$(provider_field "$choice" 1)" ]; then
    id="$choice"
  elif [ "$choice" = "$custom" ]; then
    custom_api
    return
  else
    custom_api "$choice"
    return
  fi
  pick_provider="$id" pick_label="$(provider_field "$id" 2)"
  var="$(provider_field "$id" 3)"
  ask_key "$id" "$pick_label" "$var"
  if [ -n "$var" ]; then envs=("$var=$(secret_value "$var")"); fi
  models="$(env ${envs[@]+"${envs[@]}"} "$HERMES_PY" -I "$REPO_DIR/scripts/lib/hermes-models.py" models "$id" || true)"
  choose_model "$id" "$pick_label" "$models"
}

model_chain() {
  nix eval --json "$flake.config.server.hermes" --apply 'h: [h.model] ++ map (f: { provider = f.provider; name = f.model; }) h.fallbacks' \
    | "$JQ" -r 'map("\(.name) (\(.provider))") | join(" → ")'
}

if grep -q 'fallbacks' "$local_nix" 2>/dev/null && keep "Models: $(model_chain) → the local model"; then
  :
else
  note "The main model, then the ones Hermes falls back to, in order, when one fails;"
  note "the local model (uzu) always comes last. A ChatGPT subscription logs in once the chain is chosen."
  new_providers="$(nix eval --json "$flake.config.server.hermes.providers")"
  until choose_entry "Main model · its provider (type to search)" && [ -n "$pick_provider" ]; do :; done
  main="$("$JQ" -cn --arg p "$pick_provider" --arg n "$pick_model" '{provider: $p, name: $n}')"
  chain="$pick_model ($pick_label)"
  ok "Main model: $chain"
  fallbacks="[]" n=1
  while :; do
    echo
    choose_entry "Fallback $n, after $chain · its provider" "No other: then the local model" || continue
    [ -n "$pick_provider" ] || break
    fallbacks="$("$JQ" -c --arg p "$pick_provider" --arg n "$pick_model" '. + [{provider: $p, model: $n}]' <<< "$fallbacks")"
    chain="$chain → $pick_model ($pick_label)"
    n=$((n + 1))
    ok "Then: $pick_model ($pick_label)"
  done
  set_host "$("$JQ" -cn --argjson m "$main" --argjson f "$fallbacks" --argjson p "$new_providers" \
    '{server: {hermes: {model: $m, fallbacks: $f, providers: $p}}}')"
  ok "Models: $(model_chain) → the local model"
fi

# Every provider of the chain has its key: asked above when the chain is
# chosen, here when it was skipped or the chain written by hand.
custom_keys="$(nix eval --json "$flake.config.server.hermes.providers")"
for provider in $(nix eval --json "$flake.config.server.hermes" \
  --apply 'h: [h.model.provider] ++ map (f: f.provider) h.fallbacks' | "$JQ" -r 'unique[]'); do
  if [ "$("$JQ" --arg p "$provider" 'has($p)' <<< "$custom_keys")" = true ]; then
    ask_key "$provider" "$("$JQ" -r --arg p "$provider" '.[$p].label' <<< "$custom_keys")" \
      "$("$JQ" -r --arg p "$provider" '.[$p].keyEnv // empty' <<< "$custom_keys")"
  else
    ask_key "$provider" "$(provider_field "$provider" 2)" "$(provider_field "$provider" 3)"
  fi
done

# A ChatGPT subscription in the chain logs in with a device code. Hermes keeps
# the login in its home's auth.json: before its account exists, the login is
# made in a throwaway home and kept root-only until system.sh moves it in.
codex_staged="$(dirname "$secrets")/openai-codex-auth.json"
hermes_bin="$(nix build --no-link --print-out-paths \
  "$flake.config.home-manager.users.$agent.services.hermes-agent.package")/bin/hermes"
hermes_cli() { sudo -u "$agent" -H env HERMES_HOME="$agent_home/.hermes" "$hermes_bin" "$@"; }
codex_logged_in() {
  if id "$agent" >/dev/null 2>&1; then
    ! hermes_cli auth status openai-codex 2>&1 | grep -q "logged out"
  else
    sudo test -s "$codex_staged"
  fi
}
codex_login() {
  local home
  note "Hermes logs in with a code: open the link it shows (on any device), sign in to ChatGPT, enter the code."
  if id "$agent" >/dev/null 2>&1; then
    hermes_cli auth add openai-codex --type oauth
    return
  fi
  home="$(mktemp -d)"
  chmod 700 "$home"
  # HOME too: Hermes would otherwise read this user's own ~/.hermes and ~/.codex.
  if HOME="$home" HERMES_HOME="$home" "$hermes_bin" auth add openai-codex --type oauth && [ -s "$home/auth.json" ]; then
    write_secret "$codex_staged" < "$home/auth.json"
  fi
  rm -rf "$home"
  sudo test -s "$codex_staged"
}

if nix eval --json "$flake.config.server.hermes" \
  --apply 'h: builtins.any (p: p == "openai-codex") ([h.model.provider] ++ map (f: f.provider) h.fallbacks)' | grep -q true; then
  if codex_logged_in && keep "Hermes is logged in to your ChatGPT subscription"; then
    :
  elif codex_login; then
    ok "Hermes is logged in to your ChatGPT subscription"
  else
    warn "Not logged in: Hermes falls back to the next model. Run this script again to retry."
  fi
fi
