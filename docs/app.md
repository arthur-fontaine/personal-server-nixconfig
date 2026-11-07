# The iOS app

The owner's iPhone and iPad app (`apps/hermes-ios`) is a Telegram client of
their DM with the bot: the main chat, the sub-chats, and what Hermes serves
it beside them. This page is the server's side; the contract between the two
is [app-protocol.md](app-protocol.md).

## Hermes' side

`server.hermes.app.enable` (the bootstrap's "App · Hermes' side" section,
off by default) installs the `app_topic` plugin
(`modules/hermes/plugins/app_topic`, options in `modules/hermes/options/app.nix`).
It needs BotFather's Threaded Mode, as the sub-chats do.

| Part | What it does | Where |
| --- | --- | --- |
| App topic | a topic named "App" of the DM, hidden by the app, carries JSON both ways; nothing posted there reaches the model | `app.py` |
| State | three messages the bot edits: `state` (what Hermes is doing, the questions waiting for the owner, the pet, the sub-chats), `stats`, `devices` | `app.py`, `status.py`, `questions.py` |
| Notifications | for each message that may notify, a `notify` with a short spoken version for Siri | `speech.py` |
| Stats | model usage per provider and model, fallbacks apart, over 24 h / 7 d / 30 d; CPU, memory, storage, power, battery, uptime | `usage.py`, `machine.py` |
| Pets | the pet's needs and level, `pet_generate`, its files for the app's build | `pet.py` |
| Big files | `[fichier: <url>]` links: `bigfile_fetch`, `bigfile_send` | `bigfiles.py` |
| Call mode | a WebSocket where the owner talks to Hermes | `call.py` |
| Pushes | APNs, with a paid Apple Developer team | `push.py` |

### What Hermes is doing

The plugin follows Hermes' own hooks: a request to the model is `thinking`,
a tool call `working` (with the tool and its first argument), a question
waiting for the owner `waiting_user`, a failed turn `error` for ten minutes.
The questions come from the cards themselves: every Hermes card with buttons
(an approval, a `clarify`) goes through the Telegram adapter's
`_send_control_message`, which the plugin wraps, and `owner_approval`
reports its own. The app answers a question by pressing the card's button
through Telegram, exactly as a tap would, so Hermes sees no difference.

### Notifications read aloud

Siri reads a notification as written (Announce Notifications, with AirPods).
Each message Hermes sends to the owner gets a `notify` once it has settled
(no edit for 2.5 s, or a stream's final edit), with its plain text and a
spoken version: no markdown, no links ("a link to github.com"), no code ("a
code block"), no emoji, symbols in words, two sentences at most. Hermes can
write that version itself, as a last line `🔊 …`, when its message would
sound wrong aloud (its prompt says so). Questions and approvals are
time-sensitive.

### Model usage

Hermes counts usage per session (`state.db`), and the main chat is one
session that never ends, so it cannot say "today". The plugin keeps its own
ledger, `~/.hermes/app/usage.db`, hour by hour for 31 days, from the hooks
Hermes fires for every physical call: `post_api_request` (the chat; a
fallback under its own provider and model), `api_request_error` (each failed
attempt), `post_auxiliary_call` (summaries, review, vision...). A model is
`main` when it is the chain's first, `fallback` for the rest of the chain,
`background` for auxiliary calls, `local` for uzu. Cost is Hermes' own
estimate (`agent/usage_pricing.py`), when it has a price. Not counted: the
decision models (guard and `browser_fast_act` call them directly) and the
events daemon's screening.

### The machine

CPU, memory and the data volume through psutil; power from IOKit's
`AppleSmartBattery` (`ioreg`, no root): on the adapter, the whole Mac's
draw (`PowerTelemetryData.SystemPowerIn`), on battery, voltage × current.
`powermetrics` would need root. Sampled every minute, kept as hourly
averages for a day, and integrated into the last 24 hours' kWh.

### Pets

The pet is Hermes' own (`agent/pet`, a Codex/petdex spritesheet of 8 × 9
frames in `~/.hermes/pets/<slug>/`); Hermes hatches one from a description
with `pet_generate` (or the app's `pet.generate`), through Hermes' image
generation: a base look, then one animation row per state, each grounded on
the base. The provider is the bootstrap's choice
(`server.hermes.app.images`): OpenRouter, OpenAI, or any OpenAI-compatible
API by its address and key (Hermes' `openai` image plugin pointed there:
`image_gen.openai.base_url` and `key_env`). The model must take reference
images (`/images/edits`).

The plugin keeps what Hermes does not, the tamagotchi
(`~/.hermes/app/pet-state.json`, rules in app-protocol.md §5): hunger,
energy and happiness drift with time, faster while Hermes works; feeding,
playing and sleep move them; finished turns and answered questions give xp,
and levels follow. The sprite plays the row matching what Hermes does.

For the app's build (app-delivery), the current pet is mirrored to
`~/.hermes/app/pet/`: `spritesheet.webp`, `icon.png` (the first idle frame
on a solid background, 1024 × 1024, opaque) and `pet.json` (the Codex
manifest with an integer `version`), written last. A new pet does not
reinstall the app by itself: Hermes decides when and where (`app_install`).

### Big files

Telegram takes 2 GB from the app (4 GB with Premium) and 50 MB from the bot.
Past that, a file goes through gofile.io (or SwissTransfer, with an
Infomaniak token in the secrets file as `INFOMANIAK_TOKEN`) and the message
ends with `[fichier: <url>]`. `bigfile_fetch` downloads such links into
`~/.hermes/files`; `bigfile_send` uploads a file and gives the line to end
the reply with. gofile.io's upload is its public API; reading a share page
through its API is a Premium feature, so the tool reads it the way gofile's
own website does (a guest token and its website token), which can break
without notice: the error then says to open the link in Hermes' Chrome.

### Call mode

`server.hermes.app.call.enable`. Hermes answers the call, not a separate
voice model: the owner's speech is transcribed with Hermes' STT
(`server.hermes.app.call.stt`: faster-whisper on this Mac by default, or
OpenAI, Groq...), becomes a main-chat turn starting with 🎙 (the prompt makes
those answers short and speakable), and Hermes' reply is spoken with its TTS
(`call.tts`: Microsoft's free Edge voices by default, OpenAI, ElevenLabs...)
sentence by sentence, as its drafts stream. Both stay in the chat as text.
The app asks for a call in the App topic and gets a single-use token valid
five minutes and the addresses: `ws://<host>.local:8787/call` on the local
network, and `server.hermes.app.call.publicUrl` from anywhere, when the
owner points a tunnel with TLS at that port (none is set up here).

Rejected: an omni speech model (LFM3-Omni-2B through llama.cpp's
`/v1/realtime`, OpenAI's realtime API), which would answer fast but would not
be Hermes: no memory, no tools. The latency is Hermes' own first sentence,
plus a second or so of transcription.

### Pushes

A free personal team has no APNs: the app learns of new messages only while
it runs. With a paid team, `server.hermes.app.apns` (the bootstrap asks for
the key's id, the team id, the bundle id and the `.p8`, kept in the secrets
file as `APNS_KEY`) makes the plugin push each `notify` as an alert and the
agent's state as Live Activity updates.

### Files

Everything lives in `~/.hermes/app/` (a mutable path of the Hermes account):
`topic.json` (the topic and its slot messages), `usage.db`, `machine.json`,
`pet-state.json`, `pet/`, `push.json` (device tokens), `gofile.json` (the
guest account), and `delivery.json`, written by app-delivery.
