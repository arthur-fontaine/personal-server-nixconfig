# Hermes app ⇄ Hermes protocol, version 4

Owner: `app-backend` (plugin `app_topic`, `modules/hermes/plugins/app_topic`).
`ios-app` builds against it and asks `app-backend` (hc send) for changes
instead of editing it. A breaking change bumps `v` and is logged in the
changelog at the bottom. Additive fields may appear at any time: ignore keys
you don't know.

Checked against Hermes' pinned source (`plugins/platforms/telegram/adapter.py`)
and the Bot API (https://core.telegram.org/bots/api).

## 1. Transport

- The app is a TDLib **user** client of the owner's account and shows only the
  private chat with the Hermes bot: the main chat (no topic, `chat = 0`) and
  the sub-chats (forum topics of that DM, `chat = <forum topic id>` — TDLib's
  `forum_topic_id`, the Bot API's `message_thread_id`).
- Machine traffic goes through one forum topic of that DM named exactly
  **`App`**, created by the bot (`createForumTopic`) when the gateway connects
  and none is known. The app finds it by name (if several, the one with the
  highest id) and hides it. The bot never runs a turn on what is posted there:
  the `app_topic` plugin drops those messages before the gateway dispatches
  them (`pre_gateway_dispatch` → skip), so nothing reaches the model, the
  memory or the transcript.
- **Envelope.** Every App-topic message is one JSON object, UTF-8:
  - Bot → app: sent with `parse_mode=HTML` as
    `<pre><code class="language-json">…</code></pre>`. The JSON is the
    message's **plain text** (TDLib `formattedText.text`; the `pre` is an
    entity, not characters). Always `disable_notification=true`.
  - App → bot: the JSON as the message's plain text. A surrounding
    ```` ```json … ``` ```` fence (as characters) is tolerated and stripped.
  - Required keys: `"v": 4`, `"type": <string>`. Unknown `type`: the bot
    replies `error` `unknown_type`; the app ignores unknown types.
- **Size.** Telegram caps a message at 4096 UTF-16 code units once entities
  are parsed. The bot keeps each message under that: long strings are cut
  with `…`, histories shortened; a cut list carries `"truncated": true`.
- **Rate limits** (Telegram allows about one message per second per chat,
  edits included, and 30/s per bot; a 429 gives `retry_after`):
  - the bot edits each slot message (§2) at most once every 3 s, and only
    when its JSON changed (Telegram refuses an identical edit);
  - `stats` is refreshed every 60 s, and on `stats.refresh` at most once per
    10 s;
  - `notify` messages are posted as they come, but the plugin queues every
    App-topic send behind one sender that keeps ≥ 1 s between two, and obeys
    `retry_after`;
  - the app should send at most one request per second.
- **Cleanup.** The bot deletes each request once handled. It deletes its own
  `reply` and `notify` messages after 1 hour (bots can delete messages in a
  private chat for 48 h). The app may delete a `notify` or `reply` itself as
  soon as it has read it (in a private chat both sides can delete).
- **Ids.** Every message id in this protocol (`questions[].message_id`,
  `notify.message_id`, `slots.*`, `pet.sprite_message_id`, `reply.re`,
  `ack.ids`) is the **Bot API** `message_id`, in both directions. TDLib numbers
  the same message `message_id << 20` (× 1048576); the app converts at its
  boundary (`BotAPIID` in HermesCore) and never puts a TDLib id in JSON. Chat
  ids (`chat`, `busy_chats`, `subchats[].topic_id`) are the Bot API
  `message_thread_id`, 0 for the main chat; TDLib's `forum_topic_id` is the
  same number.
- **Identity.** Only the owner's messages count (the first id of
  `TELEGRAM_ALLOWED_USERS`; the DM has no one else).

## 2. State: four slot messages, edited in place

The bot keeps one message per slot in the App topic and edits it:

| `type` | Holds | Edited when |
| --- | --- | --- |
| `state` | `agent`, `questions`, `pet`, `subchats`, `slots` | any of them changes (≤ 1 edit / 3 s) |
| `stats` | machine and model usage | every 60 s, or on `stats.refresh` |
| `devices` | where the app can be installed | `~/.hermes/app/delivery.json` changes |
| `controls` | the native commands and the current values they set (§2.4) | a value changes |

**Finding them.** No pin: in a private chat a pinned message shows on top of
the whole DM in every Telegram client, so the bot does not pin. The app reads
the App topic's history newest first and takes the newest message of each
`type`; `state.slots` gives the other two's message ids. It then follows
edits (`updateMessageContent`) and new messages (`updateNewMessage`). When a
slot message is deleted, or after a restart, the bot posts a new one (the
newest wins). A slot message older than 47 h is re-posted, so it can always
be deleted.

### 2.1 `state`

```json
{
  "v": 4, "type": "state", "updated_at": "2026-11-07T21:40:03Z",
  "slots": {"stats": 812, "devices": 813, "sprite": 790},
  "agent": {
    "status": "working", "chat": 0, "task": "Running: nix build …",
    "progress": "3 tool calls", "since": "2026-11-07T21:39:51Z",
    "busy_chats": [0, 455]
  },
  "questions": [
    {
      "id": "ea:7", "kind": "approval", "chat": 0, "message_id": 1201,
      "text": "<terminal> (plugin approval rule)\n\nReason: Rebuilds the site from a clean state\n\nask mode: every action asks: terminal: cd ~/workspace/site && rm -rf build && npm ci && npm run build",
      "summary": "Rebuilds the site from a clean state",
      "command": "<terminal> (plugin approval rule)",
      "spoken": "Hermes wants to run a command that rebuilds the site from a clean state. Allow?",
      "options": [
        {"id": "once", "label": "Once", "data_b64": "ZWE6b25jZTo3"},
        {"id": "session", "label": "Session", "data_b64": "ZWE6c2Vzc2lvbjo3"},
        {"id": "always", "label": "Always", "data_b64": "ZWE6YWx3YXlzOjc="},
        {"id": "deny", "label": "Deny", "data_b64": "ZWE6ZGVueTo3"}
      ],
      "asked_at": "2026-11-07T21:40:01Z"
    }
  ],
  "pet": {
    "id": "pip", "name": "Pip", "version": 3,
    "manifest": {"id": "pip", "displayName": "Pip", "description": "…",
                 "spritesheetPath": "spritesheet.webp", "version": 3},
    "sprite_message_id": 790,
    "mood": "working", "animation": "run", "mood_until": null
  },
  "subchats": [
    {"topic_id": 455, "name": "Taxes", "preset": "secret", "encrypted": true,
     "unlocked": false, "ttl": null, "expires_at": null}
  ]
}
```

- `agent.status`: `idle` | `thinking` (waiting on the model) | `working`
  (running a tool) | `waiting_user` (a question is open) | `error` (the last
  turn failed; back to `idle` at the next turn or after 10 min).
  `chat`: where the latest active turn runs (0 = main). `task`: a short label
  (the tool and its first argument, ≤ 80 chars), `null` when idle. `progress`:
  optional free text. `since`: when `status` last changed. `busy_chats`: every
  chat with a turn running. Drives the Live Activity and the pet's animation.
- `questions`: every question waiting for the owner, oldest first (empty when
  none). Sources: Hermes' approval card (`kind: "approval"`, callback prefix
  `ea:`), the `clarify` tool (`kind: "clarify"`, `cl:`), `owner_approval`'s
  questions (`kind: "approval"`, `oa:`) and proposals (`kind: "proposal"`,
  `op:`).
  - `id`: stable while it is open. `message_id`: the message holding the
    inline keyboard in `chat`.
  - **Answering** = pressing the button: TDLib `getCallbackQueryAnswer(chat_id,
    message_id, callbackQueryPayloadData(base64-decode(data_b64)))`. That is
    exactly what a tap in Telegram does, so Hermes resolves it the same way
    and edits the card. The app may also read the keyboard from the message
    itself (same buttons).
  - `summary`: on a card `guard` asks, one or two plain sentences in the
    owner's language: what the action does and why auto mode asks ("Hermes
    wants to delete 41 old backup snapshots on the external disk (frees
    212 GB). Auto mode asks because deleting can't be undone.";
    `guard/titles.py`). The app shows it as the question. `null` for Hermes'
    own pattern cards (their reason is a pattern name, in `text`) and a
    clarify. `detail`: on guard's cards, the raw action (`terminal: <the
    command>`, `<tool>: key: value; …`, credentials masked, cut), for a
    collapsible detail; `null` otherwise. `command`: what the card's code
    box shows: the raw command on Hermes' pattern cards, Hermes' label
    `<tool> (plugin approval rule)` on guard's, `null` for a clarify.
    `text`: the card's text without markup (Telegram's: Hermes' header and
    label, then the sentence and the raw action).
  - `spoken`: what the app says for it; guard's `summary` as is.
  - A clarify's `options` end with `{"id": "other", …}`: pressing it makes
    Hermes take the next text message in that chat as the answer.
  - On a clarify or a proposal, `text` is the question alone: the numbered
    list of the options (they are the buttons, with their full labels) and
    Hermes' "Reply "skip" to skip this question." line, in any of its
    languages, are left out. Telegram keeps both: its adapter writes the list
    (plugins/platforms/telegram/adapter.py, `send_clarify`) and the turn
    runner the hint, which a plugin cannot change.
  - A question leaves the list when answered, timed out or withdrawn.
- `pet`: see §5. `manifest` is the Codex `pet.json` (plus `version`).
  `sprite_message_id`: a message in the App topic whose document is the
  spritesheet (`spritesheet.webp`, 8 columns × 9 rows of 192×208 frames);
  download it with TDLib, cache it by `version`. `mood`, `animation`,
  `mood_until`: §5. `pet` is `null` when no pet has been hatched yet.
- `subchats`: the DM's sub-chat topics (not groups): `preset` as named in
  `/sub` (`null` when custom), `encrypted`, `unlocked` (its key is in memory
  now), `ttl` as `/sub` shows it (`"30m"`, `"session"`, `null`), `expires_at`
  (ISO, `null` when none or not computable). Private = `encrypted`. `name` is the name `/sub new` gave the topic, `null` for one opened
  before the server recorded names: take TDLib's topic name then.

### 2.2 `stats`

```json
{
  "v": 4, "type": "stats", "updated_at": "2026-11-07T21:40:00Z",
  "machine": {
    "cpu_pct": 12.5, "load": [1.2, 1.4, 1.6], "cores": 10,
    "ram_used": 17179869184, "ram_total": 34359738368,
    "disk_used": 401234567890, "disk_total": 994662584320,
    "power_w": 11.2, "energy_kwh_24h": 0.27, "battery_pct": 100,
    "charging": false, "on_ac": true, "temp_c": null,
    "uptime_s": 432000,
    "history": {"cpu": [10.1, 9.8], "ram": [49.2, 50.1], "power": [10.9, 11.2]}
  },
  "models": [
    {
      "provider": "opencode-go", "model": "deepseek-v4.1-flash", "role": "main",
      "last_used": "2026-11-07T21:39:58Z",
      "windows": {
        "24h": {"calls": 412, "tokens_in": 2310000, "tokens_out": 41000,
                "tokens_cached": 1980000, "cost_usd": 0.42, "errors": 3},
        "7d": {"…": "same keys"}, "30d": {"…": "same keys"}
      }
    }
  ]
}
```

- Bytes for sizes, watts for power. `history`: the last 24 hourly averages
  (oldest first; `ram` in %). `power_w`: the whole Mac's draw (battery
  discharge or adapter input, from IOKit's `AppleSmartBattery`); `null` when
  unknown. `energy_kwh_24h`: integrated from 1-minute samples. `temp_c`:
  `null` unless readable without root.
- `models`: one entry per (provider, model) seen in the last 30 days, sorted
  by 24 h calls. `role`: `main` (first of the chain), `fallback` (later in the
  chain), `background` (summaries, review, other auxiliary calls), `local`
  (`uzu`). Counted from Hermes' own hooks (`post_api_request`,
  `api_request_error`, `post_auxiliary_call`), so a fallback shows as its own
  model. `cost_usd`: Hermes' estimate when it has a price, else `null`.

### 2.3 `devices`

`~/.hermes/app/delivery.json`, as is, under `delivery`: the sideload
service's status of its app `hermes` (`modules/sideload`, `app_status`):

```json
{"v": 4, "type": "devices", "updated_at": "…", "delivery": {
  "v": 1, "updated": "…", "team": {"id": "ABCDE12345", "paid": false},
  "running": null, "next_refresh": "…",
  "devices": [{"id": "<udid>", "name": "iPhone", "model": "iPhone17,1", "os": "26.1",
               "reachable": true, "chosen": true, "profile_expires": "…",
               "last_install": {"at": "…", "ok": true, "error": null, "version": "1.0",
                                "build": "42", "bundle_id": "…", "input_version": 3,
                                "reason": "new pet"}}]}}
```

`chosen`: the app is installed there (and kept signed); `input_version`:
the pet's `version` it was built with; `running`: an install in progress.

`delivery` is `null` when app delivery is not set up.

### 2.4 `controls`: native commands

```json
{"v": 4, "type": "controls", "updated_at": "…",
 "permission_mode": {"value": "auto", "set": "/mode {value}",
                     "options": [{"id": "auto", "label": "Auto", "description": "…"},
                                 {"id": "ask", "label": "Ask", "description": "…"}]},
 "model": {
   "chain": [{"provider": "opencode-go", "model": "deepseek-v4.1-flash", "role": "main"},
             {"provider": "openai-codex", "model": "gpt-6-luna", "role": "fallback"},
             {"provider": "uzu", "model": "local", "role": "local"}],
   "default": {"provider": "opencode-go", "model": "deepseek-v4.1-flash", "role": "main"},
   "current": {"0": {"provider": "openai-codex", "model": "gpt-6-luna"}},
   "last": {"0": {"provider": "opencode-go", "model": "deepseek-v4.1-flash", "at": "…"}},
   "set_main": "/model {model} --provider {provider}",
   "set_subchat": "/sub set model {provider}:{model}"},
 "presets": [{"name": "aside", "default": true, "memoryRead": true, "memoryWrite": false,
              "volume": null, "tools": null, "ttl": "session", "encrypted": false, "model": null}, "…"],
 "commands": [{"id": "stop", "send": "/stop", "where": "any"},
              {"id": "btw", "insert": "/btw ", "where": "any"},
              {"id": "reasoning", "control": "picker", "send": "/reasoning {value}",
               "options": ["low", "medium", "high"], "where": "any"}, "…"]}
```

**How the app sets anything: it sends the slash command, as the owner, in the
chat it applies to** (the main chat, or the sub-chat's topic). Hermes handles
it as if typed and answers in that chat; the slot then shows the new value.
No App-topic request: one path, the one Telegram already has.

- `send`: send that text as is (fill `{value}`, `{model}`, `{provider}`,
  `{preset}`, `{name}`); `insert`: put it in the composer for the owner to
  finish. `confirm`: ask before sending, with that sentence.
- `where`: `any`, `main` (the main chat only), `subchat` (a sub-chat topic),
  `encrypted` (an encrypted sub-chat that is unlocked).
- `control`: the native UI: `picker` (its `options`), `model` (the model
  menu below), `permission_mode`, `subchat_form` (below).
- **Model menu**: `chain` lists the models this server has (main, fallbacks,
  the local one when there is one). `current[chat]` is a `/model` switch in
  force for that chat (absent: `default`); `last[chat]` is what actually
  answered last (a fallback shows here). In the main chat, set it with
  `set_main` (for that chat's session, until changed again); in a sub-chat,
  `set_subchat` pins it in the sub-chat's rules (`/sub set model`), and
  `subchats[].` in `state` does not show it, `/sub` does.
- **Permission mode** (the auto-review, `guard`): `auto` (Claude Code's auto
  mode: safe actions run, a reviewer judges the rest and blocks risky ones;
  the owner is asked after 3 blocks in a row or 20 in a session) or `ask`
  (every action but reads asks the owner). Set with `/mode auto|ask`, at
  once, kept across restarts (`server.hermes.permissions.defaultMode` is only
  the first value). `null` when guard does not report it; `set: null` would
  mean read-only.
- **Sub-chat form** (`sub.new`, main chat only): a name and a preset from
  `presets` (the `default` one first), then `/sub new <preset> <name>`. The
  bot answers in the main chat and opens the topic; it appears in
  `state.subchats`. Changing a rule later: `/sub set <key> <value>`
  (keys as in `presets`), in the topic.

The commands, with the app's labels (chosen among Hermes' ~70 and the
plugins' for one never-ending chat on a server: no `/new`, `/resume`,
`/sessions` — there is one chat; no `/compress` — unii's memory replaces it;
no `/yolo`, `/approvals` — the permission mode replaces them; no `/update`,
`/restart` — Nix and `server-rebuild` own those):

| id | Label | Does |
| --- | --- | --- |
| `stop` | Stop background work | kills the background processes |
| `retry` | Retry | re-sends the last message |
| `undo` | Undo last turn | backs up one turn |
| `btw` | Side question | asks about the conversation without interrupting the turn |
| `bg` | Run in background | a prompt in a separate background session |
| `goal` | Standing goal | Hermes works on it across turns until reached |
| `agents` | Running tasks | the agents and tasks running |
| `status` | Session status | model, tokens, context |
| `usage` | Usage and limits | token usage and rate limits |
| `reasoning` | Reasoning effort | low / medium / high |
| `model` | Model | the model menu |
| `permissions` | Permission mode | the permission picker (only when reported) |
| `sub.new` | New sub-chat | the sub-chat form |
| `sub.show` | Sub-chat rules | `/sub` in the topic |
| `sub.set` | Change a rule | `/sub set …` in the topic |
| `sub.lock` | Lock | forgets the sub-chat's key until `/sub unlock` |
| `sub.end` | End sub-chat | deletes the topic and its memory (confirm) |
| `pause` | Emergency stop | no new work until resumed (confirm) |
| `resume` | Resume work | `/pause off` |

## 3. Notifications: `notify`

For every bot message that may notify the owner, the bot posts a `notify` in
the App topic once the message has settled (no edit for 2.5 s; at once for a
stream's final edit, and for a question):

```json
{"v": 4, "type": "notify", "chat": 0, "message_id": 1187,
 "kind": "message", "interruption": "active",
 "title": "Hermes", "private": false, "body": "The build passed. 3 warnings in the …",
 "spoken": "The build passed, with three warnings."}
```

- `chat`/`message_id`: the message it is about (0 = main chat). For a
  question, the card's message and `kind: "question"` or `"approval"`.
- `title`: `Hermes`, or `Hermes · <topic name>` in a sub-chat — but never a
  private (encrypted) sub-chat's name: there it is `Hermes` and `private` is
  `true`, and the app titles it "Hermes · Private chat" in the owner's
  language (the name stays inside the unlocked chat). `body`: the message as
  plain text (markdown removed), ≤ 240 chars — except in a private sub-chat,
  where `body` is `New message` (`Hermes needs you` for a question) and
  `spoken` `New message from Hermes.` (`Hermes needs your answer.`): nothing
  of its content leaves the app (design-rules 1.4b); the app shows them in
  the owner's language. The Live Activity push drops a private sub-chat's
  task, its question's text, summary and command, and a clarify's choices.
- `spoken`: what Siri reads (Announce Notifications): no markdown, no URLs
  (a link becomes "a link to example.com"), no code (a block becomes "a code
  block"), emoji removed, units and symbols written out (`%` → "percent",
  `→` → "to"), at most two sentences / 200 chars. Written by the plugin,
  deterministically, from the final text (Hermes never writes a spoken
  version; a `🔊 …` line it may still write is removed before the message
  reaches Telegram). Empty for a written-detail message (`📎 `, §6).
- `interruption`: `time-sensitive` for questions and approvals, `active`
  otherwise.
- Not sent for: messages in the App topic, drafts, edits of an already
  notified message, messages the bot sends with `disable_notification`.

## 4. Requests (app → bot) and replies

A request is a JSON message in the App topic; `re` in the reply is the
request's message id. The bot deletes the request when it has answered.

```json
{"v": 4, "type": "stats.refresh"}
{"v": 4, "type": "reply", "re": 1302, "ok": true, "data": {}}
{"v": 4, "type": "reply", "re": 1303, "ok": false,
 "error": {"code": "busy", "message": "A pet is already being generated"}}
```

| `type` | Fields | Reply `data` |
| --- | --- | --- |
| `hello` | `app_version`, `build`, `device` (name), `device_id` (UDID if known), `pet_version` (bundled) | `{"server_version", "protocol": 3}`; the bot also re-posts any missing slot |
| `stats.refresh` | — | `{}` (the `stats` slot is edited) |
| `pet.generate` | `prompt` (what it should look like), `name` (optional) | `{"started": true}` at once; the `state.pet` changes when done (minutes), and a `notify` says so |
| `app.reinstall` | `devices` (UDIDs, optional: where it is installed, else every paired device) | the JSON printed by `hermes-app install`, i.e. `sideload install hermes` (`{"started": true, "request": "…"}`); the `devices` slot follows; `unavailable` without delivery |
| `call.state` | `active` (bool): a call starts or ends (§6) | `{"active": <bool>}` |
| `push.register` | `token_hex`, `kind` (`alert` \| `liveactivity` \| `pushtostart`), `sandbox`, `bundle_id`, `activity_id` (liveactivity) | `{"stored": true, "apns": <bool: the server can send>}` |
| `push.unregister` | `token_hex` | `{}` |
| `ack` | `ids` (message ids of `notify`/`reply`) | none: the bot deletes them |

Error codes: `bad_request`, `unknown_type`, `busy`, `unavailable` (the
feature is off on this server), `failed`.

A sub-chat is unlocked by the app itself: it sends `/sub unlock <passphrase>`
in that topic, then deletes it (unii intercepts it before anything stores it).

**Push (paid team only).** With an APNs key configured on the server
(`server.hermes.app.apns`), the bot also pushes: `notify` as an alert (with
`interruption-level` and the `spoken` text as body) to `alert` tokens, and
`state.agent`/`questions[0]` as a Live Activity content update (`event:
"update"`, `content-state` = `{"status", "task", "chat", "question"}`) to
`liveactivity` tokens; `pushtostart` starts one when a turn starts. Without
a key, tokens are stored and `apns: false`.

## 5. Pet

- **Files.** The current pet is Hermes' active pet
  (`~/.hermes/pets/<slug>/`). The plugin mirrors it to `~/.hermes/app/pet/`
  for the app's build: `pet.json` (this manifest: Codex keys + `version`, plus
  `name`), `spritesheet.webp`, `icon.png` (1024×1024 opaque sRGB: the first
  idle frame on a solid background). Written atomically, `pet.json` last.
- **Generation**: the `pet_generate` tool (Hermes) or `pet.generate`
  (app): Hermes' hatch pipeline (`agent/pet/generate`: one base look, then
  one animation row per state, packed into the Codex 8×9 atlas) through the
  image provider chosen in the bootstrap; `version` increments. Hermes then
  decides whether to rebuild and reinstall the app (`sideload_install` with
  app `hermes`), since the icon changed.
- **A companion, not a tamagotchi.** The pet mirrors Hermes and nothing
  else: no needs, levels or actions, nothing that asks for care or degrades
  when ignored. The plugin keeps only which pet is current and its version
  (`~/.hermes/app/pet-state.json`).
- **Mood**, from `agent.status` and the end of turns:

  | `mood` | When | `animation` |
  | --- | --- | --- |
  | `working` | `thinking` or `working` | `review` (thinking), `run` (a tool) |
  | `waiting` | `waiting_user` | `waiting` |
  | `happy` | for 10 s after a turn finished | `jump` |
  | `confused` | for 10 s after a turn failed | `failed` |
  | `idle` | otherwise | `idle` |

  Hermes' status wins over a beat; of several turns ending together, the
  last sets the beat; a stopped turn (`/stop`, interrupted) gets none. A
  beat is a reaction, not a state: `agent.status` stays `error` for
  10 min, the pet is `confused` for 10 s. `mood_until` (ISO) is when a
  `happy`/`confused` beat ends, `null` otherwise, so the app need not wait
  for the next edit. `animation` is the sprite row (Hermes' own mapping,
  `agent/pet/state.py`; Codex row names `running`/`waving`/`jumping` are
  aliases).
- **In the app only**: caresses (a stroke or long press on the pet: a happy
  row, a haptic, a heart), a wave toward a question as it arrives, a nod
  when it is answered. None of them is sent to Hermes.

## 6. Call mode

Everything goes through Telegram; nothing on the server is reachable from
outside. The app hears and speaks on the device (LFM3-Omni-2B: speech
recognition and synthesis), and the call is ordinary messages of the chat:

- **A call turn** is a text message the app sends as the owner, in the chat
  the call is in (the main chat, or a sub-chat's topic), whose text starts
  with **`🎙 `** (U+1F399 then a space) followed by what the owner said, as
  transcribed: `🎙 what's on my calendar tomorrow`. Plain text, no entities,
  one message per utterance. It stays in the chat as the transcript.
- **The answer** is Hermes' normal reply: native drafts in the main chat,
  edits in a topic, then the final message. The app reads it aloud as it
  streams (it may start at the first complete sentence) and stops when the
  final message arrives. For such a turn, the plugin adds to the owner's
  message (`pre_llm_call`, not the system prompt, so the prompt cache holds)
  and the prompt says: open with one short sentence that answers or says
  what Hermes will do, then short spoken sentences, no markdown, lists,
  links, code or emoji, numbers and symbols in words, and a sentence before
  a long step. A long task still goes to a background subagent (its result
  is a later message, which the app may read too).
- **Written detail** is never mixed into the spoken answer. What is better
  read than heard (links, code, lists, figures to keep) Hermes writes after
  its spoken answer under a line starting with `📎`; the plugin cuts the
  reply there before Telegram (drafts and edits stop at that line) and,
  once the reply is final, sends the rest as a **separate message whose text
  starts with `📎 `** (U+1F4CE then a space), in the same chat. The app never
  speaks a message starting with `📎`, stops speaking a streaming draft at a
  line starting with `📎`, and shows it as a normal message, marker hidden.
  Its `notify` has an empty `spoken`.
- **`call.state`** (optional): the app posts `{"v": 4, "type": "call.state",
  "active": true}` when a call starts and `false` when it ends. While a call
  is on, every turn of the owner's in Telegram gets the spoken style, even a
  follow-up typed without 🎙. A call left on (the app killed mid-call) ends by
  itself after 2 hours.
- **Barge-in** is local: the app stops speaking. What the owner says next is
  another call turn; one sent while Hermes is still working reaches the
  running turn at its next step (Hermes' steer mode), so it can redirect it.
- Interim messages Hermes posts between its tool calls ("I'm checking…")
  are messages like the others: the app may read them aloud.
- No `call.start` request, no token, no audio leaves Telegram.

## 7. Big files

- Telegram caps what the app (TDLib, user) uploads at 2 GB (4 GB Premium),
  the bot at 50 MB up / 20 MB down. Beyond, the file goes to **gofile.io**
  (guest upload, links `https://gofile.io/d/<code>`), or **SwissTransfer**
  (`https://swisstransfer.infomaniak.com/dl/<uuid>`, v2; the older
  `https://www.swisstransfer.com/d/<uuid>` is read too) when an Infomaniak
  token is set,
  and the message ends with one line per file: `[fichier: <url>]`.
- Hermes reads such links with `bigfile_fetch` (into `~/.hermes/files/`) and
  sends a file the bot cannot with `bigfile_send`, which uploads to gofile.io
  and posts `[fichier: <url>]` (Telegram's 50 MB bot limit; also anything
  over 2 GB).

## Changelog

- v4 (2026-11-09, after Arthur's first real use). Added: §1 "Ids" (every
  message id is the Bot API's, every chat id the Bot API thread id; the app
  converts TDLib's); `questions[].detail` (guard's raw action);
  `questions[].summary` is now guard's plain sentence for any tool, in the
  owner's language, and `spoken` says it as is; a clarify's or proposal's
  `text` is the question alone (no option list, no skip hint); the written
  detail message `📎 ` of a call turn (§6). Removed: the `🔊 <text>` spoken
  override (§3). The bot accepts requests whatever their `v`; the app
  ignores it.

- v3 (2026-11-08, Arthur's change: the pet is a companion, not a
  tamagotchi). Removed: the requests `pet.feed`, `pet.play`, `pet.sleep`,
  `pet.wake` (they now answer `unknown_type`); `state.pet`'s `hunger`,
  `energy`, `happiness`, `xp`, `level`, `xp_next`, `asleep`, `updated_at`.
  Changed: `pet.mood` is now `idle` | `working` | `waiting` | `happy` |
  `confused` (§5), `pet.animation` plays `jump` for the happy beat (no more
  `wave` after a turn or `jump` on a level up). Added: `pet.mood_until`.
  The bot accepts requests whatever their `v`.

- v2, additive (2026-11-07, Arthur's addition): the `controls` slot (§2.4),
  native commands and the values they set; `state.slots.controls`.
- v2 (2026-11-07, Arthur's change): call mode goes through Telegram only.
  Removed: `call.start`, its URL, token and the server's WebSocket and
  STT/TTS. Added: the call turn, a message starting with `🎙 `, and the
  optional `call.state` request (§6). `v` is 2 in every message.
- v1 (2026-11-07): first precise version. Changes from the v0 draft: the
  state is three edited slot messages (`state`, `stats`, `devices`) instead
  of one pinned message (4096-character cap; a pin shows on top of the DM);
  `question` → `questions` (several can be open), answered by pressing the
  button (`data_b64`); `notify` carries `kind`, `interruption`, `body`;
  `chat` is a topic id (0 = main); `pet` gains `happiness`, `asleep`,
  `animation`, `sprite_message_id`; requests gain `hello`, `pet.wake`,
  `push.register`; call mode is ios-app's WebSocket shape.
