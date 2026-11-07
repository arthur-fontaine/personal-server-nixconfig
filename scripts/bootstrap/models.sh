# ── Models: the main one, then its fallbacks ────────────────────────────────
# Hermes tries them in order when one fails (a limit reached, an outage), for
# that turn. Then the local model, if any (below). Written to
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
  local name="${1:-}" slug var
  [ -n "$name" ] || name="$(gum input --header "Its name (e.g. Mistral)")"
  [ -n "$name" ] || return 1
  slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
  # Not a name Hermes gives a provider of its own, nor the local model's.
  while [ "$slug" = uzu ] || grep -qxF "$slug" <<< "$provider_names"; do slug="$slug-custom"; done
  var="$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')_API_KEY"
  api_url="$("$JQ" -r --arg s "$slug" '.[$s].url // empty' <<< "$new_providers")"
  openai_api "$name" "$var" || return 1
  new_providers="$("$JQ" -c --arg s "$slug" --arg l "$name" --arg u "$api_url" --arg k "$var" --argjson keyed "$([ -n "$api_key" ] && echo true || echo false)" \
    '.[$s] = {label: $l, url: $u, keyEnv: (if $keyed then $k else null end)}' <<< "$new_providers")"
  pick_provider="$slug" pick_label="$name"
  choose_model "$slug" "$name" "$api_models"
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

if grep -q 'fallbacks' "$local_nix" 2>/dev/null && keep "Models: $(model_chain)"; then
  :
else
  note "The main model, then the ones Hermes falls back to, in order, when one fails: only ones"
  note "with funds or quota left. A ChatGPT subscription logs in once the chain is chosen."
  new_providers="$(nix eval --json "$flake.config.server.hermes.providers")"
  until choose_entry "Main model · its provider (type to search)" && [ -n "$pick_provider" ]; do :; done
  main="$("$JQ" -cn --arg p "$pick_provider" --arg n "$pick_model" '{provider: $p, name: $n}')"
  chain="$pick_model ($pick_label)"
  ok "Main model: $chain"
  fallbacks="[]" n=1
  while :; do
    echo
    choose_entry "Fallback $n, after $chain · its provider" "No other fallback" || continue
    [ -n "$pick_provider" ] || break
    fallbacks="$("$JQ" -c --arg p "$pick_provider" --arg n "$pick_model" '. + [{provider: $p, model: $n}]' <<< "$fallbacks")"
    chain="$chain → $pick_model ($pick_label)"
    n=$((n + 1))
    ok "Then: $pick_model ($pick_label)"
  done
  set_host "$("$JQ" -cn --argjson m "$main" --argjson f "$fallbacks" --argjson p "$new_providers" \
    '{server: {hermes: {model: $m, fallbacks: $f, providers: $p}}}')"
  ok "Models: $(model_chain)"
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

# ── The local model ─────────────────────────────────────────────────────────
# One of the models pinned in pkgs/uzu-models.nix, served by uzu on this Mac's
# GPU, or none (server.uzu). It screens the events and answers the sub-chats
# that pin uzu:local; without it, nothing is screened and those run on the
# main model. It may also be the last fallback (server.hermes.localFallback),
# but the main chat's prompt takes it minutes a step. uzu runs on Apple
# silicon only, and only the models that leave this Mac's memory room to work
# are offered.

mac_memory_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
apple_silicon="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
local_summary() {
  if [ "$(setting server.uzu.enable)" != 1 ]; then
    echo "none"
    return 0
  fi
  printf '%s' "$(setting server.uzu.model)"
  if [ "$(setting server.hermes.localFallback)" = 1 ]; then printf ', also the last fallback'; fi
  echo
}

echo
if grep -q '^ *uzu = ' "$local_nix" 2>/dev/null && keep "Local model: $(local_summary)"; then
  :
else
  none="None: no model on this Mac"
  local_rows=""
  if [ "$apple_silicon" = 1 ]; then
    # label · weights · id, for what fits.
    local_rows="$(nix eval --json "$flake.pkgs.uzu-models" --apply 'm: builtins.attrValues (builtins.mapAttrs
      (id: v: { inherit id; inherit (v) label memoryGB minMemoryGB; }) (removeAttrs m [ "override" "overrideDerivation" ]))' \
      | "$JQ" -r --argjson ram "$mac_memory_gb" \
        'sort_by(-.memoryGB)[] | select(.minMemoryGB <= $ram) | "\(.label) · \(.memoryGB) GB on the GPU · \(.id)"' || true)"
  fi
  if [ -z "$local_rows" ]; then
    warn "No local model fits this Mac (Apple silicon: ${apple_silicon:-no}, ${mac_memory_gb} GB of memory)."
    choice="$none"
  else
    note "A model on this Mac's GPU (uzu) screens incoming messages before Hermes sees them, and"
    note "answers the private sub-chats: free and private, but small and slow. Without one, nothing"
    note "is screened (groups and bulk mail are dropped) and those sub-chats use the main model."
    choice="$( { echo "$local_rows"; echo "$none"; } \
      | gum choose --header "Local model (this Mac: ${mac_memory_gb} GB of memory)" || true)"
    [ -n "$choice" ] || choice="$none"
  fi
  if [ "$choice" = "$none" ]; then
    set_host '{"server":{"uzu":{"enable":false},"hermes":{"localFallback":false}}}'
    case "$(setting server.hermes.memory.compactionModel)" in
      uzu:*)
        set_host '{"server":{"hermes":{"memory":{"compactionModel":null}}}}'
        note "The summaries ran on the local model: they use the background model now."
        ;;
    esac
  else
    local_fallback=false
    if ask --default=false "Also answer the main chat with it when every remote model fails? It takes minutes a step there."; then
      local_fallback=true
    fi
    set_host "$("$JQ" -cn --arg m "${choice##* · }" --argjson f "$local_fallback" \
      '{server: {uzu: {enable: true, model: $m}, hermes: {localFallback: $f}}}')"
  fi
  ok "Local model: $(local_summary)"
fi


# ── Decision models ─────────────────────────────────────────────────────────
# Models answering System One (POST /v1/systemone) with probabilities over
# given options instead of text (modules/hermes/options/decision.nix): one may
# pick each action of computer use, one may review each action Hermes takes.
# Any provider speaking System One, local ones included, and any model.

# id|label|URL|Authorization scheme|key variable|key page|suggested models
decision_providers=(
  "baseten|Baseten|https://inference.baseten.co|Api-Key|BASETEN_API_KEY|https://app.baseten.co/settings/api_keys|decision-models/baseten-mammoth-27b-latest decision-models/baseten-elephant-9b-latest"
  "typesafe|TypeSafe (Jev)|https://api.typesafe.ai|Bearer|TYPESAFE_API_KEY|https://console.typesafe.ai|jev-latest"
)
decision_other="Another System One API, local ones too (its address)"

decision_status() { # url scheme model key: the HTTP status of a one-question request
  local url="${1%/}" headers=(-H "Content-Type: application/json")
  case "$url" in */v1/systemone) ;; *) url="$url/v1/systemone" ;; esac
  [ -n "$4" ] && headers+=(-H "Authorization: $2 $4")
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$url" "${headers[@]}" \
    -d "$("$JQ" -cn --arg m "$3" '{model: $m, state: {message: "A setup check."},
      questions: {check: {type: "choice", instructions: "Is this a setup check?", criteria: {yes: "Yes", no: "No"}}}}')" || true
}
decision_off() { set_host "$("$JQ" -cn --arg u "$1" '{server: {hermes: {decision: {($u): {enable: false}}}}}')"; }
decision_ready() { # use: on, with its key when it takes one
  local key_env
  [ "$(setting "server.hermes.decision.$1.enable")" = 1 ] || return 1
  key_env="$(setting "server.hermes.decision.$1.keyEnv")"
  [ -z "$key_env" ] || [ -n "$(secret_value "$key_env")" ]
}

# use, the model offered first: provider, model, key, checked, then written.
decision_setup() {
  local use="$1" first="$2" line labels=() choice id="" label url scheme key_env page models name model key status
  for line in "${decision_providers[@]}"; do labels+=("$(cut -d'|' -f2 <<< "$line")"); done
  choice="$(gum choose --header "Its provider" "${labels[@]}" "$decision_other")" || return 1
  for line in "${decision_providers[@]}"; do
    [ "$(cut -d'|' -f2 <<< "$line")" = "$choice" ] || continue
    IFS='|' read -r id label url scheme key_env page models <<< "$line"
  done
  if [ -z "$id" ]; then
    url="$(gum input --header "Its address (the base URL, or the full /v1/systemone endpoint)" --placeholder "http://127.0.0.1:8100")"
    [ -n "$url" ] || return 1
    scheme="$(gum choose --header "Its key goes in the Authorization header as" "Bearer <key>" "Api-Key <key>" "No key (a local model)")"
    case "$scheme" in
      "No key"*) scheme="Bearer" key_env="" ;;
      *)
        scheme="${scheme%% *}"
        name="$(gum input --header "A short name for it (its key's variable)" --placeholder "mylab")"
        key_env="$(tr '[:lower:]-' '[:upper:]_' <<< "$name" | tr -cd 'A-Z0-9_')_DECISION_API_KEY"
        ;;
    esac
    page="" models=""
  fi
  # A suggestion (the one offered first on top), or any model typed in.
  if [ -n "$models" ]; then
    model="$(printf '%s\n' $models | awk -v f="$first" '$0 == f { print; next } { rest = rest $0 "\n" } END { printf "%s", rest }' \
      | gum filter --no-strict --header "Its model (type any id)" --placeholder "$first")" || true
    [ -n "$model" ] || model="$first"
  else
    model="$(gum input --header "Its model's id")"
    [ -n "$model" ] || return 1
  fi
  local reask=""
  while :; do
    key=""
    if [ -n "$key_env" ]; then
      [ -n "$reask" ] || key="$(secret_value "$key_env")"
      if [ -n "$key" ]; then
        note "Its key is in the secrets file ($key_env)."
      else
        key="$(gum input --password --header "Its key ($key_env${page:+, from $page}; empty to skip)" | tr -d '[:space:]')"
        [ -n "$key" ] || { warn "No key: left off."; return 1; }
      fi
    fi
    status="$(decision_status "$url" "$scheme" "$model" "$key")"
    case "$status" in
      200) ok "$model answers"; break ;;
      401 | 403)
        warn "It refused that key (HTTP $status)."
        # Asked again, not wiped: another use may share it.
        reask=1
        ;;
      *)
        warn "It did not answer the check (${status:-no answer}, HTTP status)."
        gum confirm --default=false "Keep it anyway?" || return 1
        break
        ;;
    esac
  done
  [ -n "$key" ] && [ "$key" != "$(secret_value "$key_env")" ] && set_secret "$key_env" "$key"
  set_host "$("$JQ" -cn --arg u "$use" --arg url "$url" --arg m "$model" --arg s "$scheme" --arg k "$key_env" \
    '{server: {hermes: {decision: {($u): {enable: true, url: $url, model: $m, authScheme: $s,
      keyEnv: (if $k == "" then null else $k end)}}}}}')"
  unset key
}

echo
if decision_ready computerUse \
  && keep "Computer use: $(setting server.hermes.decision.computerUse.model) picks each action"; then
  :
else
  note "A decision model can drive Hermes' Chrome for it: it picks each click and field from the"
  note "page's own controls instead of reading screenshots, so a step takes a fraction of a second"
  note "instead of several, for a fraction of the cost. Hermes still writes the text it types."
  if ask "Use a decision model for computer use?"; then
    decision_setup computerUse decision-models/baseten-elephant-9b-latest \
      || { decision_off computerUse; warn "Computer use stays on screenshots."; }
  elif [ "$(setting server.hermes.decision.computerUse.enable)" = 1 ]; then
    decision_off computerUse
  fi
fi

echo
if decision_ready approval \
  && keep "Auto-review: $(setting server.hermes.decision.approval.model) reviews each action"; then
  :
else
  note "A decision model can review each action Hermes is about to take, from your own messages"
  note "only: what is low-risk runs at once, and what is riskier when you asked for it (a send, only that"
  note "exact one); anything else (what an incoming message or a web page asked for) waits for your yes in Telegram."
  note "Without one, every action but reads waits for your yes."
  if ask "Review Hermes' actions with a decision model?"; then
    decision_setup approval decision-models/baseten-mammoth-27b-latest \
      || { decision_off approval; warn "No auto-review: every action but reads waits for your yes in Telegram."; }
  elif [ "$(setting server.hermes.decision.approval.enable)" = 1 ]; then
    decision_off approval
  fi
fi

# What runs without asking (server.hermes.permissions.defaultMode): only with
# a review model, since without one auto mode asks for the same calls anyway.
# /mode auto|ask changes it later from the chat.
if decision_ready approval; then
  if grep -q 'defaultMode' "$local_nix" 2>/dev/null \
    && keep "Permission mode: $(setting server.hermes.permissions.defaultMode)"; then
    :
  else
    note "auto: safe calls run, the review model judges the rest and blocks risky ones (Claude Code's auto mode)."
    note "ask: every action but reads asks you. /mode auto|ask switches later from the chat."
    mode="$(gum choose --header "What may Hermes do without asking you?" --selected "$(setting server.hermes.permissions.defaultMode)" \
      auto ask)" || mode=""
    if [ -n "$mode" ]; then
      set_host "$("$JQ" -cn --arg m "$mode" '{server: {hermes: {permissions: {defaultMode: $m}}}}')"
      ok "Permission mode: $mode"
    fi
  fi
fi
