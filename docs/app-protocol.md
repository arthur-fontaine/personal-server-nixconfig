# Hermes app ⇄ Hermes protocol, version 1

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
  - Required keys: `"v": 1`, `"type": <string>`. Unknown `type`: the bot
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
- **Identity.** Only the owner's messages count (the first id of
  `TELEGRAM_ALLOWED_USERS`; the DM has no one else).

## 2. State: three slot messages, edited in place

The bot keeps one message per slot in the App topic and edits it:

| `type` | Holds | Edited when |
| --- | --- | --- |
| `state` | `agent`, `questions`, `pet`, `subchats`, `slots` | any of them changes (≤ 1 edit / 3 s) |
| `stats` | machine and model usage | every 60 s, or on `stats.refresh` |
| `devices` | where the app can be installed | `~/.hermes/app/delivery.json` changes |

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
  "v": 1, "type": "state", "updated_at": "2026-11-07T21:40:03Z",
  "slots": {"stats": 812, "devices": 813, "sprite": 790},
  "agent": {
    "status": "working", "chat": 0, "task": "Running: nix build …",
    "progress": "3 tool calls", "since": "2026-11-07T21:39:51Z",
    "busy_chats": [0, 455]
  },
  "questions": [
    {
      "id": "ea:7", "kind": "approval", "chat": 0, "message_id": 1201,
      "text": "Dangerous command: rm -rf ~/tmp/build",
      "summary": "Delete the build folder in your temp directory",
      "command": "rm -rf ~/tmp/build",
      "spoken": "Hermes asks to delete the build folder in your temp directory. Allow?",
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
    "animation": "run",
    "mood": "focused", "hunger": 35, "energy": 70, "happiness": 82,
    "xp": 1240, "level": 6, "xp_next": 1500, "asleep": false,
    "updated_at": "2026-11-07T21:39:51Z"
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
  - `summary`: a plain-language summary of a command (filled by
    `app-delivery`'s approval change; `null` until then or when not a
    command). `command`: the raw command (or the tool and its arguments),
    `null` for a clarify. `text`: the card's text without markup.
  - A clarify's `options` end with `{"id": "other", …}`: pressing it makes
    Hermes take the next text message in that chat as the answer.
  - A question leaves the list when answered, timed out or withdrawn.
- `pet`: see §5. `manifest` is the Codex `pet.json` (plus `version`).
  `sprite_message_id`: a message in the App topic whose document is the
  spritesheet (`spritesheet.webp`, 8 columns × 9 rows of 192×208 frames);
  download it with TDLib, cache it by `version`. `animation`: the sprite row
  to play (`idle`, `run`, `review`, `waiting`, `wave`, `jump`, `failed`;
  Codex row names `running`/`waving`/`jumping` are aliases). `null` when no
  pet has been hatched yet.
- `subchats`: the DM's sub-chat topics (not groups): `preset` as named in
  `/sub` (`null` when custom), `encrypted`, `unlocked` (its key is in memory
  now), `ttl` as `/sub` shows it (`"30m"`, `"session"`, `null`), `expires_at`
  (ISO, `null` when none or not computable). Private = `encrypted`. `name` is the name `/sub new` gave the topic, `null` for one opened
  before the server recorded names: take TDLib's topic name then.

### 2.2 `stats`

```json
{
  "v": 1, "type": "stats", "updated_at": "2026-11-07T21:40:00Z",
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

`app-delivery`'s `~/.hermes/app/delivery.json`, as is, under `delivery`:

```json
{"v": 1, "type": "devices", "updated_at": "…", "delivery": {
  "v": 1, "updated": "…", "team": {"id": "ABCDE12345", "paid": false},
  "running": null, "next_refresh": "…",
  "devices": [{"id": "<udid>", "name": "iPhone", "model": "iPhone17,1", "os": "26.1",
               "reachable": true, "profile_expires": "…",
               "last_install": {"at": "…", "ok": true, "error": null, "version": "1.0",
                                "build": "42", "pet_version": 3}}]}}
```

`delivery` is `null` when app delivery is not set up.

## 3. Notifications: `notify`

For every bot message that may notify the owner, the bot posts a `notify` in
the App topic once the message has settled (no edit for 2.5 s; at once for a
stream's final edit, and for a question):

```json
{"v": 1, "type": "notify", "chat": 0, "message_id": 1187,
 "kind": "message", "interruption": "active",
 "title": "Hermes", "body": "The build passed. 3 warnings in the …",
 "spoken": "The build passed, with three warnings."}
```

- `chat`/`message_id`: the message it is about (0 = main chat). For a
  question, the card's message and `kind: "question"` or `"approval"`.
- `title`: `Hermes`, or `Hermes · <topic name>` in a sub-chat. `body`: the
  message as plain text (markdown removed), ≤ 240 chars.
- `spoken`: what Siri reads (Announce Notifications): no markdown, no URLs
  (a link becomes "a link to example.com"), no code (a block becomes "a code
  block"), emoji removed, units and symbols written out (`%` → "percent",
  `→` → "to"), at most two sentences / 200 chars. Written by the plugin,
  deterministically, from the final text; when Hermes ends a message with a
  line `🔊 <text>`, that text is used instead (and the line is kept out of
  the notification body).
- `interruption`: `time-sensitive` for questions and approvals, `active`
  otherwise.
- Not sent for: messages in the App topic, drafts, edits of an already
  notified message, messages the bot sends with `disable_notification`.

## 4. Requests (app → bot) and replies

A request is a JSON message in the App topic; `re` in the reply is the
request's message id. The bot deletes the request when it has answered.

```json
{"v": 1, "type": "pet.feed"}
{"v": 1, "type": "reply", "re": 1302, "ok": true, "data": {"hunger": 5}}
{"v": 1, "type": "reply", "re": 1303, "ok": false,
 "error": {"code": "busy", "message": "A pet is already being generated"}}
```

| `type` | Fields | Reply `data` |
| --- | --- | --- |
| `hello` | `app_version`, `build`, `device` (name), `device_id` (UDID if known), `pet_version` (bundled) | `{"server_version", "protocol": 1}`; the bot also re-posts any missing slot |
| `stats.refresh` | — | `{}` (the `stats` slot is edited) |
| `pet.feed` / `pet.play` / `pet.sleep` / `pet.wake` | — | the pet's new needs (`hunger`, `energy`, `happiness`, `xp`, `level`, `asleep`) |
| `pet.generate` | `prompt` (what it should look like), `name` (optional) | `{"started": true}` at once; the `state.pet` changes when done (minutes), and a `notify` says so |
| `app.reinstall` | `devices` (UDIDs, optional: all reachable) | the JSON printed by `hermes-app install` (`{"started": true}`) |
| `call.start` | — | `{"url", "lan_url", "token", "expires"}` (§6) |
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
  image provider chosen in the bootstrap. The new pet starts at level 1 with
  full needs; `version` increments. Hermes then decides whether to rebuild
  and reinstall the app (`app_install`), since the icon changed.
- **Needs** (0–100, integers): `hunger` rises 4/h (8/h while Hermes works);
  `energy` falls 3/h awake and 6/h while working, rises 12/h asleep;
  `happiness` falls 2/h, faster (5/h) when hunger > 70 or energy < 20.
- **Actions**: `feed` hunger −40 (refused at < 10: "not hungry"), happiness +5,
  xp +5; `play` happiness +25, energy −15, hunger +10, xp +15 (refused asleep
  or at energy < 15); `sleep` asleep until energy 100 or `wake`; `wake`.
  Asleep while Hermes works: the pet wakes.
- **XP**: +2 per finished turn, +5 per answered question, +10 per day with
  every need above 30. Level n needs `100·n·(n+1)/2` total xp
  (`xp_next`).
- **Mood** (first that matches): `asleep`, `hungry` (hunger > 70), `tired`
  (energy < 20), `sad` (happiness < 30), `focused` (Hermes working), `happy`
  (happiness > 70), `content`.
- **Animation**: from `agent.status` as Hermes' own mapping does
  (`agent/pet/state.py`): working → `run`, thinking → `review`, waiting_user
  → `waiting`, error → `failed`, a turn just finished → `wave` (10 s), level
  up → `jump` (10 s), else `idle`.

## 6. Call mode

`call.start` → reply data:

```json
{"url": "wss://hermes.example.com/call", "lan_url": "ws://personal-server.local:8787/call",
 "token": "q3…", "expires": "2026-11-07T21:45:00Z"}
```

- `url` is the public address (`server.hermes.app.call.publicUrl`, behind a
  tunnel with TLS) or `null`; `lan_url` works on the same network (iOS:
  `NSAllowsLocalNetworking`). Try `url` first when set.
- The token is single-use, valid 5 minutes to connect; send it as
  `Authorization: Bearer <token>` (or `?token=` when a header is impossible).
  One call at a time: a second connection gets `{"type":"end","reason":"busy"}`.
- **Client → server**: binary frames of PCM16LE mono 24 kHz audio (~40 ms
  each); text frames `{"type":"input.end"}` (end of the owner's utterance;
  the server also ends one after 700 ms of silence), `{"type":"interrupt"}`
  (barge-in: stop speaking), `{"type":"hangup"}`.
- **Server → client**: binary frames of PCM16LE mono 24 kHz audio; text
  frames `{"type":"state","state":"listening"|"thinking"|"speaking"}`,
  `{"type":"transcript","role":"user"|"assistant","text","final":bool}`,
  `{"type":"clear"}` (drop queued audio), `{"type":"end","reason":"hangup"|
  "timeout"|"busy"|"error"|"server_stopping"}`, `{"type":"error","message"}`.
- **What answers**: Hermes itself, in the main chat: the owner's utterance is
  transcribed and becomes a main-chat turn (prefixed `🎙`, so Hermes answers
  short and speakable), and Hermes' reply is spoken sentence by sentence as
  it streams. The turn and its reply stay in the chat as text.

## 7. Big files

- Telegram caps what the app (TDLib, user) uploads at 2 GB (4 GB Premium),
  the bot at 50 MB up / 20 MB down. Beyond, the file goes to **gofile.io**
  (guest upload, links `https://gofile.io/d/<code>`), or **SwissTransfer**
  (`https://www.swisstransfer.com/d/<uuid>`) when an Infomaniak token is set,
  and the message ends with one line per file: `[fichier: <url>]`.
- Hermes reads such links with `bigfile_fetch` (into `~/.hermes/files/`) and
  sends a file the bot cannot with `bigfile_send`, which uploads to gofile.io
  and posts `[fichier: <url>]` (Telegram's 50 MB bot limit; also anything
  over 2 GB).

## Changelog

- v1 (2026-11-07): first precise version. Changes from the v0 draft: the
  state is three edited slot messages (`state`, `stats`, `devices`) instead
  of one pinned message (4096-character cap; a pin shows on top of the DM);
  `question` → `questions` (several can be open), answered by pressing the
  button (`data_b64`); `notify` carries `kind`, `interruption`, `body`;
  `chat` is a topic id (0 = main); `pet` gains `happiness`, `asleep`,
  `animation`, `sprite_message_id`; requests gain `hello`, `pet.wake`,
  `push.register`; call mode is ios-app's WebSocket shape.
