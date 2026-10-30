# Hermes on this server

## One chat that never ends

Your Telegram DM with the bot is the main chat, for daily use, forever.
Answers appear as they are written (Telegram's drafts; edited messages in the
sub-chats' topics), and messages sent while Hermes was down are answered when
it is back. There
is no session to reset and nothing to compact by hand: the unii plugin
(`modules/hermes/plugins/unii`) logs every message and keeps a view of the whole
chat, recent messages word for word and older ones as merged summaries, so each
reply is written with constant-size context that covers everything. The model
zooms into a summary when it needs the detail. This is Victor Taelin's UniiChat
design; the plugin's README lists what was taken from where.

Hermes' built-in memory, session search and compaction are off: the view
replaces all three. The CLI (`hermes` as the Hermes account over SSH) is the
main chat too. Subagents and cron jobs read the main memory but never write it.

## Sub-chats

Your DM with the bot, outside any topic, is the main chat. With BotFather's
Threaded Mode and "Disallow users to create new threads" both on, only the bot
creates topics, so whatever you send outside a topic stays in the main chat,
and each topic is a sub-chat, kept out of the main chat by its policy. Open one
from the main chat with `/sub new [preset] [name]` (`/sub new secret Taxes`),
and type `/sub` in it to see the policy. A temporary topic is deleted,
Telegram's copy too, when it expires or right after `/sub end`.

Each group with the bot is a sub-chat too, and so is each topic of a group.

| Setting | Values | Effect |
| --- | --- | --- |
| `memoryRead` | on/off | sees the main chat's memory, read-only |
| `memoryWrite` | on/off | its messages also go into the main chat's memory |
| `volume` | a name, or none | a memory shared with the sub-chats naming the same volume; none: its own |
| `tools` | `a,b`, all, none | the toolsets (`web`, `file`, `terminal`, `browser`, `computer_use`, …) or tools it may use |
| `ttl` | `30m`, `6h`, `7d`, `session`, none | when it is wiped: that long after its last message, when its session ends, or never |
| `encrypted` | on/off | its memory is AES-256-GCM, unlocked with `/sub unlock <passphrase>` |
| `model` | `provider:model`, none | e.g. `uzu:local`, the model on this Mac |

Presets, defined in Nix (`server.hermes.subchats.presets`), set them all at
once with `/sub preset <name>`:

| Preset | For |
| --- | --- |
| `aside` (new groups start here) | a side question that knows everything but leaves no trace once its session ends |
| `project` | long-running work in the shared `projects` volume, apart from daily life |
| `secret` | secrets: no main memory either way, the encrypted `vault` volume, the local model, file and terminal tools only |
| `temp` | a throwaway chat on the local model, no tools, gone an hour after its last message |

Volumes are declared in `server.hermes.memory.volumes`; `encrypted = true`
there makes every sub-chat using the volume encrypted.

### What encryption covers

An encrypted volume's files hold only ciphertext; the key is derived from your
passphrase and kept in memory until `/sub lock` or a restart, and `/sub unlock`
is intercepted before Hermes stores or logs it. After each turn the plain
transcript Hermes keeps of that chat is deleted (best effort: a failure is
logged, not retried). Still in clear: Telegram's copy of the chat (bot chats are not end-to-end
encrypted; delete the group in Telegram to remove it), the
running gateway's memory until it restarts, fragments Hermes may write to
`~/.hermes/logs`, and the model provider for that turn, unless the sub-chat
runs on `uzu:local`.

## What Hermes may touch

Enforced by macOS, not by the model (`modules/hermes/system/access`):

| Rule | How |
| --- | --- |
| reads anything | an inherited ACL on your home; `sudo hermes-read cat\|ls\|stat <path>` for the rest |
| writes or deletes only what it created in the last 24 h | it runs as its own account, so your files were never writable; `hermes-freeze` (every 5 min) hands its files to you behind a deny ACL once they are 24 h old, so it must copy them to change them |
| changes the system only through this repository | it clones, commits, pushes, then `sudo server-rebuild` |
| installs any software | `nix shell` / `nix profile install` for itself, this repository for good |

The exceptions are its own state, which must stay writable to work at all:
`~/.hermes`, `~/.cache`, `~/.config`, `~/.local`, `~/Library`, its Nix profile
(`server.hermes.access.mutablePaths`). Files it leaves in its per-user temp
folder are not frozen either; macOS deletes them after three days. Hermes, its
commands and the freeze daemon reach Desktop, Documents and Downloads through
the Full Disk Access granted once to their launcher
(`modules/hermes/system/access/full-disk.nix`); without it, files in those
folders are neither readable nor frozen.

## Apple apps

The Hermes account signs in to your Apple Account (the bootstrap's second run),
so Hermes works with your Apple apps: through its bundled Apple skills and
their CLIs (`pkgs/apple`), and two menu bar apps that serve MCP and hold their
own permissions (`modules/hermes/agent/apple.nix`):

| App | Through | macOS permission (to the launcher) |
| --- | --- | --- |
| Messages | `imsg` ([steipete/imsg](https://github.com/steipete/imsg)) | Full Disk Access (reading), Automation (sending) |
| Reminders | `remindctl` ([steipete/remindctl](https://github.com/steipete/remindctl)) | Reminders |
| Notes | `memo` ([antoniorodr/memo](https://github.com/antoniorodr/memo)) | Automation |
| Find My | FindMy.app's window, `peekaboo` ([steipete/Peekaboo](https://github.com/steipete/Peekaboo)) | Screen Recording, Accessibility |
| Calendar, Contacts, Mail (reading), Maps, Music, Shortcuts, Voice Memos, Weather, Phone (call history, calls you confirm), Voicemail | [iMCP](https://github.com/mattt/iMCP), MCP over stdio | each to iMCP itself, as you turn its services on; Local Network to the launcher |
| HomeKit | [HomeClaw](https://github.com/omarshahine/HomeClaw) (Mac App Store), MCP over HTTP on 127.0.0.1:9090 | home data, to HomeClaw |
| Anything else | AppleScript (`osascript`), `shortcuts run`, computer use | Automation |

iMCP's own Reminders, Notes and Messages services stay off (Nix sets them, with
Hermes trusted as a client and its self-updates off): the skills do more there.
The skills' permissions belong to `/Library/Hermes/hermes-launcher`, which
starts the gateway, so they hold across Hermes updates. A revoked one: run the bootstrap
again over SSH, looking at the Mac.

## Integrations: WhatsApp, Instagram, Discord, 1Password…

Each of your other services is an integration, off until you turn it on
(`server.hermes.integrations.<name>.enable`, which the bootstrap asks for):
`whatsapp`, `instagram`, `discord`, `homeassistant` (Hermes' official plugin:
the `ha_*` tools), `homekit` (HomeClaw), `onepassword`,
`runpod`, `github` (notifications). Its skill, MCP server and events come with
it, and Hermes' instructions mention only those that are on. Apple's apps are
not integrations: they come with the Mac.

| What | Through | Set up by the bootstrap |
| --- | --- | --- |
| WhatsApp | [wacli](https://github.com/openclaw/wacli), a linked device of your number; `wacli sync --follow --presence-mode quiet` keeps its store (`~/.local/state/wacli`) current without showing you online, so your phone keeps its notifications; the `whatsapp` skill | the QR code to scan in WhatsApp → Linked devices |
| Instagram | instagram.com in Hermes' always-open Google Chrome (no API exists for a personal account; `modules/hermes/agent/browser.nix`): one persistent profile (`~/.hermes/browser-profile`), DevTools on loopback for Hermes' browser tools and the events daemon; the `instagram` skill | your first login, on the Mac's screen |
| Discord | discord.com in the same Chrome (no API for a user account); the `discord` skill reads and sends, and the events daemon keeps a Discord tab open for its notifications | your first login, on the Mac's screen |
| 1Password | a service account reading one vault (`server.hermes.onepassword.vault`, "Hermes"): `browser_vault` fills its Login items into pages without the model seeing them; `server.hermes.onepassword.env` maps variables to `op://` references | its token, into the secrets file |

For Instagram and Discord, put a Login item each in that vault with the
website `https://www.instagram.com` or `https://discord.com` (the page's origin must match exactly), your
username and password, and its one-time password if you use two-factor
authentication: Hermes logs in again by itself when the session ends.

WhatsApp, Instagram and Discord all act as you, through clients their terms do not
allow (an unofficial linked device, an automated browser): they may restrict
an account that behaves like a bot. The skills tell Hermes to go at a person's
pace and to confirm before it sends or posts anything.

## Models

- A chain, chosen by the bootstrap (or set in `hosts/local.nix`): the main model
  (`server.hermes.model`), then its fallbacks in order (`server.hermes.fallbacks`),
  then the local model (`server.hermes.localFallback`). When one fails (a limit
  reached, an outage, an expired login), Hermes goes on with the next for that
  turn, and tries the main one again on the next turn ([Hermes' fallback
  providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers)).
  For example: your ChatGPT subscription, then OpenCode's DeepSeek, then uzu.
- Any provider Hermes knows, any of its models: the bootstrap lists them from
  Hermes itself (`scripts/lib/hermes-models.py`, the provider's live list when
  it has one), asks for the provider's key as soon as it is chosen, and takes a
  model id typed in too.
- Any other OpenAI-compatible API (a gateway, a self-hosted server): a name, its
  address and its key, checked on its `/models`; written as
  `server.hermes.providers.<name> = { url; keyEnv; }`, a provider like the others.
- ChatGPT subscription: provider `openai-codex`, `gpt-6-luna` first (every plan's
  default). The bootstrap logs Hermes in with a device code (a link and a code,
  from any device) once its account exists; the login lives in
  `~/.hermes/auth.json` on the Hermes account.
- OpenCode Zen: `deepseek-v4.1-flash`, paid as you go. OpenCode's free models
  (`*-free`) answer only its own app: through the API they return HTTP 429
  "Free usage limit reached" from the first request.
- Local: uzu serves Qwen 3.5 9B on the GPU at `127.0.0.1:8000`
  (`server.uzu`), for the sub-chats that pin `uzu:local`. Compactions can use it
  too: `server.hermes.memory.compactionModel = "uzu:local"`.
