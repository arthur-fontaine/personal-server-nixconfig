# ── The coding agent: Pi in a microVM ──────────────────────────────────────
# server.hermes.sandbox (docs/sandbox.md): Hermes hands a coding task to Pi,
# in an isolated VM. Its providers, models and thinking levels are Pi's own,
# read from the pi-ai the guest image runs (scripts/lib/pi-models.mjs), and
# only providers taking an API key: the VM gets a placeholder that the host
# swaps for the key, which could not stand in for a login's refreshing
# token. Written to hosts/local.nix; the key goes to the secrets file.

step "Coding agent"

sandbox_summary() {
  local advisor="no advisor"
  if [ "$(setting server.hermes.sandbox.advisor.enable)" = 1 ]; then
    advisor="its advisor $(setting server.hermes.sandbox.advisor.model) at $(setting server.hermes.sandbox.advisor.effort)"
  fi
  echo "Coding agent: Pi on $(setting server.hermes.sandbox.model) at $(setting server.hermes.sandbox.thinking), $advisor"
}

# Pi's catalog, built once (the guest's tree is the image's anyway).
pi_ai="" pi_node=""
pi_catalog() {
  [ -n "$pi_ai" ] && return 0
  note "Getting Pi's lists of providers and models..."
  pi_ai="$(nix build --no-link --print-out-paths "$flake.pkgs.hermes-sandbox.guest" || true)"
  pi_node="$(nix build --no-link --print-out-paths "$flake.pkgs.nodejs_24" || true)"
  if [ -z "$pi_ai" ] || [ -z "$pi_node" ]; then
    pi_ai=""
    warn "Could not build Pi's tree for its lists."
    return 1
  fi
  pi_ai="$pi_ai/node_modules/@earendil-works/pi-ai" pi_node="$pi_node/bin/node"
}
pi_models() { "$pi_node" "$REPO_DIR/scripts/lib/pi-models.mjs" "$pi_ai" "$@"; }

# The provider ($1 offered first). Sets pp_id, pp_label, pp_var (Pi's
# variable for the key), pp_secret (the secrets file's), pp_hosts (its API's,
# comma-separated).
choose_pi_provider() {
  local rows choice line
  rows="$(pi_models providers)"
  choice="$( {
    awk -F'\t' -v first="$1" '$1 == first { print $2 " · " $1 }' <<< "$rows"
    awk -F'\t' -v first="$1" '$1 != first { print $2 " · " $1 }' <<< "$rows"
  } | gum filter --height 15 --header "Pi's provider (one taking an API key; type to search)" || true)"
  [ -n "$choice" ] || return 1
  line="$(awk -F'\t' -v id="${choice##* · }" '$1 == id' <<< "$rows")"
  [ -n "$line" ] || return 1
  IFS=$'\t' read -r pp_id pp_label pp_var pp_secret pp_hosts <<< "$line"
}

# A model of the provider ($1, $2 its label), $3 offered first, $4 the
# question; or one typed in. Sets pick.
choose_pi_model() {
  local other="Another model: type its id" models choice
  models="$(pi_models models "$1")"
  choice="$( {
    if [ -n "$3" ] && grep -qxF "$3" <<< "$models"; then echo "$3"; fi
    grep -vxF -e "$3" -e "" <<< "$models" || true
    echo "$other"
  } | gum filter --no-strict --height 15 --header "$2 · $4" --placeholder "Type to search, or a model id" || true)"
  if [ "$choice" = "$other" ]; then choice="$(gum input --header "$2 · model id" || true)"; fi
  pick="$choice"
  [ -n "$pick" ]
}

# A thinking level the model ($1 provider, $2 id) supports, $4 offered first
# when it does. Sets pick.
choose_level() { # provider model header preferred
  local levels selected=()
  levels="$(pi_models levels "$1" "$2")"
  if grep -qxF "$4" <<< "$levels"; then selected=(--selected "$4"); fi
  pick="$(gum choose --header "$3" ${selected[@]+"${selected[@]}"} $levels || true)"
  [ -n "$pick" ]
}

sandbox_setup() {
  local current model_id thinking advisor advisor_model advisor_effort same other off choice hosts
  pi_catalog || return 1
  current="$(setting server.hermes.sandbox.model)"
  choose_pi_provider "${current%%/*}" || return 1
  ok "Provider: $pp_label"
  # The model set so far when it is this provider's, else this one's
  # suggestion (OpenCode Go's is the default's).
  model_id=""
  [ "${current%%/*}" = "$pp_id" ] && model_id="${current#*/}"
  [ -n "$model_id" ] || [ "$pp_id" != opencode-go ] || model_id="deepseek-v4.1-flash"
  choose_pi_model "$pp_id" "$pp_label" "$model_id" "Pi's model" || return 1
  model_id="$pick"
  choose_level "$pp_id" "$model_id" "$model_id · thinking level" \
    "$([ "${current#*/}" = "$model_id" ] && setting server.hermes.sandbox.thinking || echo high)" || return 1
  thinking="$pick"
  ok "Pi: $pp_id/$model_id at $thinking"

  note "Pi's advisor reviews its plan, its failures and its end: a second call of a model, at a higher effort."
  same="Same model ($model_id)" other="Another model of $pp_label" off="No advisor"
  choice="$(gum choose --header "Pi's advisor" "$same" "$other" "$off" || true)"
  [ -n "$choice" ] || return 1
  advisor=true advisor_model="$pp_id/$model_id"
  if [ "$choice" = "$off" ]; then
    advisor=false
  else
    if [ "$choice" = "$other" ]; then
      choose_pi_model "$pp_id" "$pp_label" "" "the advisor's model" || return 1
      advisor_model="$pp_id/$pick"
    fi
    choose_level "$pp_id" "${advisor_model#*/}" "${advisor_model#*/} · the advisor's effort" max || return 1
    advisor_effort="$pick"
    ok "Advisor: $advisor_model at $advisor_effort"
  fi

  ask_key "$pp_id" "$pp_label" "$pp_secret" "each coding session fails at once without it."
  hosts="$("$JQ" -cn --arg h "$pp_hosts" '$h | split(",")')"
  set_host "$("$JQ" -cn --arg m "$pp_id/$model_id" --arg t "$thinking" --arg k "$pp_secret" --arg v "$pp_var" \
    --argjson h "$hosts" --argjson a "$advisor" --arg am "$advisor_model" --arg ae "${advisor_effort:-max}" \
    '{server: {hermes: {sandbox: {enable: true, model: $m, thinking: $t, keyEnv: $k, piKeyEnv: $v, keyHosts: $h,
      advisor: (if $a then {enable: true, model: $am, effort: $ae} else {enable: false} end)}}}}')"
  ok "$(sandbox_summary)"
}

if [ "$(setting server.hermes.sandbox.enable)" = 1 ] \
  && [ -n "$(secret_value "$(setting server.hermes.sandbox.keyEnv)")" ] \
  && keep "$(sandbox_summary)"; then
  :
else
  note "Hermes can hand a coding task on one of your git repositories to Pi, a coding agent running in"
  note "an isolated VM with a copy of that repository; Pi asks Hermes for anything outside it."
  if ask "Set up a coding agent?"; then
    until sandbox_setup; do
      gum confirm "Try again?" || { warn "No coding agent."; break; }
    done
  elif [ "$(setting server.hermes.sandbox.enable)" = 1 ]; then
    set_host '{"server":{"hermes":{"sandbox":{"enable":false}}}}'
  fi
fi
