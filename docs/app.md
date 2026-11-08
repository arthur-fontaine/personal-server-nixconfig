# The Hermes app

An iPhone and iPad app for Hermes (`apps/hermes-ios`): a Telegram client of
the owner's DM with the bot (the main chat, the sub-chats) and what Hermes
serves it beside them. What it does and how it is made: [its
README](../apps/hermes-ios/README.md) and
[design](../apps/hermes-ios/docs/design.md); the contract between the app and
Hermes: [app-protocol.md](app-protocol.md). This page is the server's side:
what Hermes serves the app, then how this Mac builds and installs it.

Two switches, both asked by the bootstrap: `server.hermes.app.enable`, Hermes
serving the app (without it the app is a plain Telegram client of the DM),
and `server.hermes.app.delivery.enable`, this Mac building and installing it
(without it, build it yourself from `apps/hermes-ios`). Turn on both for the
whole loop: a new pet becomes the app's icon at its next reinstall.

## Hermes' side

`server.hermes.app.enable` (the bootstrap's "App · Hermes' side" section,
off by default) installs the `app_topic` plugin
(`modules/hermes/plugins/app_topic`, options in `modules/hermes/options/app.nix`).
It needs BotFather's Threaded Mode, as the sub-chats do.

| Part | What it does | Where |
| --- | --- | --- |
| App topic | a topic named "App" of the DM, hidden by the app, carries JSON both ways; nothing posted there reaches the model | `app.py` |
| State | four messages the bot edits: `state` (what Hermes is doing, the questions waiting for the owner, the pet, the sub-chats), `stats`, `devices`, `controls` (native commands and their current values) | `app.py`, `status.py`, `questions.py` |
| Notifications | for each message that may notify, a `notify` with a short spoken version for Siri | `speech.py` |
| Stats | model usage per provider and model, fallbacks apart, over 24 h / 7 d / 30 d; CPU, memory, storage, power, battery, uptime | `usage.py`, `machine.py` |
| Pets | the pet's needs and level, `pet_generate`, its files for the app's build | `pet.py` |
| Big files | `[fichier: <url>]` links: `bigfile_fetch`, `bigfile_send` | `bigfiles.py` |
| Call turns | a message starting with 🎙 is answered as on the phone | `__init__.py` (`call_turn`) |
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
An approval guard escalates for a long command carries guard's title for it
(`question.summary`, "Deletes the build folder"), read aloud as "Hermes wants
to run a command that deletes the build folder"; Hermes' own pattern cards
have none.

### Native commands

The app offers a few of Hermes' commands natively, listed with their current
values in the `controls` message: the permission mode (guard's `auto` or
`ask`, `/mode`), the model (the chain this server has, the `/model` switch in
force per chat, and what answered last), the reasoning effort, a form for a
new sub-chat (a name and one of the presets), and buttons for `/stop`,
`/retry`, `/undo`, `/btw`, `/bg`, `/goal`, `/agents`, `/status`, `/usage`,
`/sub …` and `/pause`. The app sets a value by sending the command itself in
the chat it applies to, so Hermes handles it as typed; the plugin looks again
a few seconds after any command. Left out on purpose: one chat means no
`/new`, `/resume` or `/sessions`; unii replaces `/compress`; the permission
mode replaces `/yolo` and `/approvals`; Nix owns `/update` and `/restart`.

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

For the app's build ([Delivery](#delivery)), the current pet is mirrored to
`~/.hermes/app/pet/`: `spritesheet.webp`, `icon.png` (the first idle frame
on a solid background, 1024 × 1024, opaque) and `pet.json` (the Codex
manifest with an integer `version`), written last. A new pet does not
reinstall the app by itself: Hermes decides when and where
(`sideload_install` with app `hermes`).

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

Nothing on the server: the app hears and speaks on the device
(LFM3-Omni-2B) and the call is messages of the chat. What the owner says is
sent as a message starting with 🎙, in the main chat or the sub-chat the call
is in; Hermes answers as usual, as drafts that stream, and the app reads them
aloud. For those turns the plugin adds the spoken style to the owner's
message (`pre_llm_call`: the system prompt, and its cache, stay as they are),
and the prompt says the same: one short sentence first, then short spoken
sentences, no markdown, links, code or emoji, and a sentence before a long
step. The transcript stays in the chat. While the app says a call is on (`call.state`), every
turn of the owner's gets that style, a follow-up typed without 🎙 too.

An earlier design had the server transcribe and speak over a WebSocket of its
own; it was dropped so that everything goes through Telegram and nothing on
this Mac is reachable from outside.

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
guest account), and `delivery.json`, written by the sideload service
([Delivery](#delivery)).

## Delivery

With `server.hermes.app.delivery.enable` (the bootstrap's "The Hermes app"
step), the app is one app of the sideload service ([sideload.md](sideload.md)),
named `hermes`, declared in `modules/hermes/system/sideload.nix`: built from
`apps/hermes-ios` at the deployed revision, signed with your Apple Account,
installed on your devices over Wi-Fi and re-signed before it expires.

1. Before each build the current pet, which the App topic writes to
   `~/.hermes/app/pet/`, is copied in: `icon.png` (1024×1024) becomes the app
   icon (`HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png`),
   `pet.json` and `spritesheet.webp` go to `Pet/`; `pet.json`'s `version` is
   recorded with the install.
2. Its settings go in as build settings, through the environment:
   `HERMES_TEAM_ID`, `HERMES_BUNDLE_ID_PREFIX`
   (`org.personal-server.hermes.<team id>` unless `bundleIdPrefix`),
   `HERMES_PAID_TEAM`, `HERMES_TG_API_ID` / `HERMES_TG_API_HASH` (the secrets
   file's `TELEGRAM_API_ID` / `_HASH`) and `HERMES_BOT_USERNAME` (the bot's,
   from Telegram's `getMe`).
3. Its devices are written to `~/.hermes/app/delivery.json` after every
   change, which the App topic posts as its `devices` slot; the app's
   "reinstall" (`app.reinstall`) runs `hermes-app install`, a shim over
   `sideload install hermes` (`hermes-app status|devices|run` likewise). An
   earlier `delivery.json` is read once, so its devices carry over.

A free team allows 3 sideloaded apps per device: the Hermes app is one, and
takes two of the 10 App IDs a week (the app and its widgets). No push
notifications on a free team (`HERMES_PAID_TEAM=0`): the app gets news while
it runs and at background refreshes (a few a day); with a paid team, Hermes
pushes them ([Pushes](#pushes)).

Hermes decides when to reinstall: `sideload_install` with `app: "hermes"`
after a new pet, when you ask, or after a failed install.
