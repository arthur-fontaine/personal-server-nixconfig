# Sourced by scripts/bootstrap-macos.sh, in its order.
# ── Check: the local model, and an event end to end ────────────────────────

uzu_port="$(setting server.uzu.port)"
uzu_model="$(setting server.uzu.model)"
uzu_url="http://127.0.0.1:$uzu_port/v1"
uzu_ask() { # system prompt, user message, extra JSON fields
  curl -fsS --max-time 120 "$uzu_url/chat/completions" -H 'Content-Type: application/json' \
    -d "$("$JQ" -n --arg m "$uzu_model" --arg s "$1" --arg u "$2" --argjson x "${3:-{\}}" \
      '{model: $m, messages: [{role: "system", content: $s}, {role: "user", content: $u}],
        temperature: 0, max_tokens: 40, enable_thinking: false} + $x')" \
    | "$JQ" -r '.choices[0].message.content'
}

if gui_session && [ "$(setting server.uzu.enable)" = 1 ]; then
  step "The local model (uzu)"
  if ! curl -fsS "$uzu_url/models" >/dev/null 2>&1; then
    note "At its first start uzu downloads its model (about 5 GB): this can take a while."
    gum spin --title "Waiting for uzu" -- bash -c \
      "for _ in \$(seq 360); do curl -fsS '$uzu_url/models' >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1" || true
  fi
  if answer="$(uzu_ask "Answer with one word." "Say ready.")" && [ -n "$answer" ]; then
    ok "uzu answers ($uzu_model): $answer"
    # The events daemon's own question (hermes_events/triage.py), on an invitation.
    verdict="$(uzu_ask "You screen events for a person's assistant. Decide whether this event may call for the person to do, decide or know something. Answer with the JSON only." \
      "A new message on whatsapp from Martin (direct chat): on prend un verre ce soir ?" \
      '{"response_format": {"type": "json_schema", "json_schema": {"name": "triage", "schema": {"type": "object", "properties": {"may_need_the_user": {"type": "boolean"}, "urgency": {"type": "string", "enum": ["now", "today", "later"]}}, "required": ["may_need_the_user", "urgency"], "additionalProperties": false}}}}' || true)"
    if [ "$("$JQ" -r '.may_need_the_user' <<< "$verdict" 2>/dev/null)" = true ]; then
      ok "Its typed triage flags an invitation: $verdict"
    else
      warn "Its triage did not flag a test invitation: ${verdict:-no answer}"
    fi
  else
    warn "uzu does not answer at $uzu_url: see $agent_home/Library/Logs/uzu.log"
  fi

  events_port="$(setting server.hermes.events.port)"
  webhook_health="http://127.0.0.1:$(setting server.hermes.events.webhookPort)/health"
  # The gateway was just restarted (Start, above): give it a minute.
  [ "$(setting server.hermes.events.enable)" = 1 ] && gum spin --title "Waiting for Hermes' webhook server" -- bash -c \
    "for _ in \$(seq 30); do curl -fsS '$webhook_health' >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1" || true
  if [ "$(setting server.hermes.events.enable)" = 1 ] \
    && curl -fsS --max-time 5 "$webhook_health" >/dev/null 2>&1 \
    && ask "Send a fake WhatsApp message through Hermes' events? A proposal should then reach your Telegram main chat."; then
    # A message as wacli would post it, signed the same way (X-Wacli-Signature),
    # from an id no real account has, so a "yes, answer him" reaches nobody.
    body="$("$JQ" -cn --arg id "setup-test-$(date +%s)" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{Chat: "setup-test@s.whatsapp.net", ID: $id, SenderJID: "setup-test@s.whatsapp.net", Timestamp: $ts,
        FromMe: false, ChatName: "Martin (setup test, not a real person)", Text: "On prend un verre ce soir ?"}')"
    webhook_secret="$(sudo sed -n 's/^WEBHOOK_SECRET=//p' "$secrets")"
    signature="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$webhook_secret" -hex | sed 's/^.*= //')"
    unset webhook_secret
    if curl -fsS --max-time 10 "http://127.0.0.1:$events_port/whatsapp" -H "X-Wacli-Signature: $signature" \
      -H 'Content-Type: application/json' -d "$body" >/dev/null; then
      ok "Sent: within $(( $(setting server.hermes.events.batchSeconds) / 60 + 1 )) minutes or so, Hermes should propose something in Telegram"
      note "Nothing? See $agent_home/Library/Logs/hermes-events.log and ~/.hermes/logs on the Hermes account."
    else
      warn "The events daemon does not answer on port $events_port: see $agent_home/Library/Logs/hermes-events.log"
    fi
  fi
fi

gum style --border rounded --padding "0 2" --foreground 42 "The server is set up." \
  "$(gum style --faint 'Message your bot on Telegram. Later changes: edit, push, sudo server-rebuild.')"
