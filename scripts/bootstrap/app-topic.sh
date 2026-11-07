# ── The app: Hermes' side ───────────────────────────────────────────────────
# What Hermes serves the owner's iOS app (server.hermes.app, docs/app.md):
# the hidden App topic, the pets' image provider (OpenRouter, OpenAI, or any
# OpenAI-compatible API by its address, checked as the models' are), call
# mode's speech providers, and APNs for a paid team. Writes hosts/local.nix
# and the keys to the secrets file, before system.sh applies them.

step "App · Hermes' side"

app_summary() {
  local images call
  if [ "$(setting server.hermes.app.enable)" != 1 ]; then
    echo "off"
    return 0
  fi
  images="$(setting server.hermes.app.images.provider)"
  call="off"
  if [ "$(setting server.hermes.app.call.enable)" = 1 ]; then
    call="$(setting server.hermes.app.call.stt) → Hermes → $(setting server.hermes.app.call.tts)"
  fi
  echo "on; pets drawn by ${images:-nobody}; calls: $call"
}

# Pets: who draws them. Sets the images part of the patch.
app_images() {
  local choice model models key
  local openrouter="OpenRouter (many image models, one key)" openai="OpenAI (gpt-image)"
  local custom="Another OpenAI-compatible API (its address)" none="None: no new pets"
  note "Hermes can hatch a new pet for the app (its icon too) with an image model that takes"
  note "reference images: about ten images a pet."
  choice="$(gum choose --header "Pets · image provider" "$openrouter" "$openai" "$custom" "$none")" || choice="$none"
  case "$choice" in
    "$openrouter")
      ask_key openrouter OpenRouter OPENROUTER_API_KEY "no new pets."
      key="$(secret_value OPENROUTER_API_KEY)"
      models="$(curl -s --max-time 15 "https://openrouter.ai/api/v1/models?output_modalities=image" \
        | "$JQ" -r '.data[]?.id // empty' 2>/dev/null || true)"
      model="$( { echo "openai/gpt-image-2"; grep -vxF "openai/gpt-image-2" <<< "$models" || true; } \
        | gum filter --no-strict --height 12 --header "Pets · OpenRouter model (type any id)" --placeholder "openai/gpt-image-2")" || true
      app_patch="$("$JQ" -c --arg m "${model:-openai/gpt-image-2}" '.images = {provider: "openrouter", model: $m, baseUrl: null}' <<< "$app_patch")"
      [ -n "$key" ] || warn "Without its key, pet_generate fails until you add OPENROUTER_API_KEY."
      ;;
    "$openai")
      ask_key openai OpenAI OPENAI_API_KEY "no new pets."
      model="$(printf '%s\n' gpt-image-2 gpt-image-1.5 \
        | gum filter --no-strict --header "Pets · OpenAI model (type any id)" --placeholder gpt-image-2)" || true
      app_patch="$("$JQ" -c --arg m "${model:-gpt-image-2}" '.images = {provider: "openai", model: $m, baseUrl: null}' <<< "$app_patch")"
      ;;
    "$custom")
      api_url="$(setting server.hermes.app.images.baseUrl)"
      if openai_api "The image API" APP_IMAGES_API_KEY "https://images.example.com/v1"; then
        model="$( { [ -z "$api_models" ] || echo "$api_models"; } \
          | gum filter --no-strict --height 12 --header "Pets · its image model (type its id)" --placeholder "gpt-image-2")" || true
        [ -n "$model" ] || model="$(gum input --header "Its image model's id")"
        app_patch="$("$JQ" -c --arg u "$api_url" --arg m "$model" \
          '.images = {provider: "custom", baseUrl: $u, model: (if $m == "" then null else $m end), keyEnv: "APP_IMAGES_API_KEY"}' <<< "$app_patch")"
      else
        warn "No image API: no new pets."
        app_patch="$("$JQ" -c '.images = {provider: null}' <<< "$app_patch")"
      fi
      ;;
    *) app_patch="$("$JQ" -c '.images = {provider: null}' <<< "$app_patch")" ;;
  esac
}

# Call mode: who hears and who speaks; Hermes answers in between.
app_call() {
  local stt tts voice url
  local stt_local="On this Mac (Whisper: free, private)" stt_openai="OpenAI" stt_groq="Groq (fast, cheap)"
  local tts_edge="Microsoft's voices (free)" tts_openai="OpenAI" tts_eleven="ElevenLabs (the most natural)"
  note "Call mode: talk to Hermes from the app as on a phone call. What you say is transcribed,"
  note "Hermes answers in the main chat, and its answer is read aloud as it is written."
  if ! ask "Allow call mode?"; then
    app_patch="$("$JQ" -c '.call = {enable: false}' <<< "$app_patch")"
    return 0
  fi
  stt="$(gum choose --header "Call · who transcribes you" "$stt_local" "$stt_openai" "$stt_groq")" || stt="$stt_local"
  case "$stt" in
    "$stt_openai") stt=openai; ask_key openai OpenAI OPENAI_API_KEY "calls cannot hear you." ;;
    "$stt_groq") stt=groq; ask_key groq Groq GROQ_API_KEY "calls cannot hear you." ;;
    *) stt=local ;;
  esac
  tts="$(gum choose --header "Call · who speaks Hermes' answers" "$tts_edge" "$tts_openai" "$tts_eleven")" || tts="$tts_edge"
  case "$tts" in
    "$tts_openai") tts=openai; ask_key openai OpenAI OPENAI_API_KEY "calls stay silent." ;;
    "$tts_eleven") tts=elevenlabs; ask_key elevenlabs ElevenLabs ELEVENLABS_API_KEY "calls stay silent." ;;
    *) tts=edge ;;
  esac
  voice="$(gum input --header "Its voice (empty: the provider's default)" \
    --placeholder "$( [ "$tts" = edge ] && echo fr-FR-HenriNeural || echo "a voice id" )")"
  note "On your network the app reaches this Mac directly. From anywhere, it needs a tunnel with"
  note "TLS to port $(setting server.hermes.app.call.port) (a Cloudflare tunnel, Tailscale Funnel...)."
  url="$(gum input --value "$(setting server.hermes.app.call.publicUrl)" \
    --header "Its public address (empty: your network only)" --placeholder "wss://call.example.com/call")"
  app_patch="$("$JQ" -c --arg s "$stt" --arg t "$tts" --arg v "$voice" --arg u "$url" \
    '.call = {enable: true, stt: $s, tts: $t, voice: (if $v == "" then null else $v end),
              publicUrl: (if $u == "" then null else $u end)}' <<< "$app_patch")"
}

# APNs: pushes while the app is closed, for a paid Apple Developer team only.
app_apns() {
  local key_id team bundle p8
  note "With a paid Apple Developer team, Hermes can push notifications and Live Activity updates"
  note "while the app is closed (an APNs key: developer.apple.com → Keys → +, Apple Push Notifications)."
  if ! ask --default=false "Send pushes through APNs (a paid team only)?"; then
    app_patch="$("$JQ" -c '.apns = {enable: false}' <<< "$app_patch")"
    return 0
  fi
  key_id="$(gum input --value "$(setting server.hermes.app.apns.keyId)" --header "The key's id (10 characters)")"
  team="$(gum input --value "$(setting server.hermes.app.apns.teamId)" --header "Your team id")"
  bundle="$(gum input --value "$(setting server.hermes.app.apns.bundleId)" --header "The app's bundle id")"
  if [ -n "$(secret_value APNS_KEY)" ] && ! gum confirm --default=false "The key is in the secrets file. Replace it?"; then
    :
  else
    p8="$(gum input --header "The .p8 file's path" --placeholder "$HOME/Downloads/AuthKey_XXXXXXXXXX.p8")"
    p8="${p8/#\~/$HOME}"
    if [ -r "$p8" ]; then
      # One line in the secrets file: the plugin turns \n back into newlines.
      set_secret APNS_KEY "$(awk 'BEGIN { ORS = "\\n" } { print }' "$p8")"
      ok "APNs key written (delete $p8 once you have it elsewhere)"
    else
      warn "No such file: no pushes until the key is in the secrets file (APNS_KEY)."
    fi
  fi
  app_patch="$("$JQ" -c --arg k "$key_id" --arg t "$team" --arg b "$bundle" \
    '.apns = {enable: true, keyId: $k, teamId: $t, bundleId: $b}' <<< "$app_patch")"
}

if [ "$(setting server.hermes.app.enable)" = 1 ] && keep "App: $(app_summary)"; then
  :
elif ! ask "Serve Hermes' iOS app (its hidden topic, pets, calls)?"; then
  [ "$(setting server.hermes.app.enable)" != 1 ] || set_host '{"server":{"hermes":{"app":{"enable":false}}}}'
  ok "App: off"
else
  app_patch='{"enable": true}'
  app_images
  echo
  app_call
  echo
  app_apns
  set_host "$("$JQ" -cn --argjson a "$app_patch" '{server: {hermes: {app: $a}}}')"
  ok "App: $(app_summary)"
  note "Threaded Mode must be on for the bot (the Telegram step), as for the sub-chats."
fi
unset app_patch api_key
