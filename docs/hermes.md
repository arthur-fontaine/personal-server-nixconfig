# Hermes on this server

## One chat that never ends

Your Telegram DM with the bot is the main chat, for daily use, forever.
Answers appear as they are written (Telegram's drafts; edited messages in the
sub-chats' topics), and messages sent while Hermes was down are answered when
it is back. A message sent while it is working reaches the turn at its next
step (`display.busy_input_mode: steer`), and Hermes answers it there and then
carries on; the main chat's turns are short (see "The main chat is a front
desk"), so that is seconds. A photo or a file, or a message sent once the turn
has made its last call, gets its own turn after it. There
is no session to reset and nothing to compact by hand: the unii plugin
(`modules/hermes/plugins/unii`) logs every message and keeps a view of the whole
chat, recent messages word for word and older ones as merged summaries, so each
reply is written with constant-size context that covers everything. The model
zooms into a summary when it needs the detail. This is Victor Taelin's UniiChat
design; the plugin's README lists what was taken from where.

Hermes' built-in memory, session search and compaction are off: the view
replaces all three. The CLI (`hermes` as the Hermes account over SSH) is the
main chat too. Subagents and cron jobs read the main memory but never write it.

What it costs stays small: a tool call and its result are logged as one line
(what a tool returned is the tool's to show again), so only your words and
Hermes' are summarized, each with the 8 KB of chat before it; within a turn,
only the last three tool results keep their screenshots and full text in what
the model is sent (the transcript keeps everything). The summaries and Hermes'
own review after a turn, which writes skills, run on
`server.hermes.backgroundModel`: by default the main model. Another one keeps a
subscription's quota (ChatGPT's) for the chat, but pick one you watch: when it
fails (no funds left), the memory stops summarizing.

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

Without a local model (`server.uzu.enable = false`), `secret` and `temp` run on
the main model, whose provider then reads them, and `/sub set model uzu:local`
is refused; a preset or `compactionModel` that names `uzu:` fails the build.

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
| Mail (moving, flagging, marking read) | AppleScript (`osascript`) | Automation |
| Calendar, Contacts, Mail (reading), Maps, Music, Shortcuts, Voice Memos, Weather, Phone (call history, calls you confirm), Voicemail | [iMCP](https://github.com/mattt/iMCP), MCP over stdio | each to iMCP itself, as you turn its services on; Local Network to the launcher |
| HomeKit | [HomeClaw](https://github.com/omarshahine/HomeClaw) (Mac App Store), MCP over HTTP on 127.0.0.1:9090 | home data, to HomeClaw |
| Anything else | AppleScript (`osascript`, System Events for other apps' windows), `shortcuts run`, computer use | Automation |

Computer use is Cua Driver (`modules/hermes/agent/computer-use.nix`). While
the repository runs a newer driver than Hermes pins (`pkgs/cua-driver.nix`),
Hermes' own `computer_use` tool is off, since its clicks no longer reach that
driver, and Hermes drives the driver's own MCP tools (`mcp__cua__*`) instead;
the guard lets the ones that only look run without review.

Web search is OpenAI's own, run server-side by the Codex model; reading a page
(`web_extract`) goes through Firecrawl's keyless tier (`modules/hermes/agent/tools.nix`),
since that search cannot extract.

Web pages go faster through `browser_fast_act` (`modules/hermes/fast-act`), once
the bootstrap's Models section has its key: Cua Driver snapshots the page in
Hermes' Chrome, a decision model answering System One picks the operation and its
target among the page's elements, in one request (browser-use's
[jev-ultrafast](https://github.com/browser-use/jev-ultrafast) shape)
(by default Baseten's [elephant-1](https://www.baseten.co/library/elephant-1/);
any Jev-compatible one through `server.hermes.decision.computerUse`), Cua Driver acts,
until the model says the goal is reached. Hermes gives the goal and every text
to type, in full (jev-ultrafast has a small LLM write it); the model only picks
which text goes into which field. It is Cua's [jev-use](https://cua.ai/docs/how-to-guides/driver/jev-use)
loop, not yet in a release, configured with the names of Cua's OpenJev adapter
(`OPENJEV_*`): when Cua or Hermes ships it, `modules/hermes/fast-act`,
`modules/hermes/agent/fast-act.nix` and `modules/hermes/options/decision.nix`
go, and the settings keep their meaning. Until then `pkgs/cua-driver.nix`
provides a Cua Driver new enough (0.38.0; Hermes pins 0.21.0).

## Sending a file to the user

Hermes attaches a file to a reply with a `MEDIA:<path>` tag (or a markdown
image), and the gateway sends it only from a place it considers safe: not
`~/.config`, `~/.ssh`, `~/Library/Keychains`, `/etc`, nor Hermes' own stores
(`gateway/platforms/base.py`, `validate_media_delivery_path`). A path it
refuses is dropped without a word, so a reply could claim an attachment the
user never got — a screenshot of the browser lives under `~/.config` by
default, which is how the user asked four times for an image that never left
the Mac.

Two things here: the gateway's allowlist (`gateway.media_delivery_allow_dirs`,
`modules/hermes/agent/browser.nix`) opens the harness' screenshot folder,
`~/.config/browser-harness/tmp`, and only it; and the `outbox` plugin
(`modules/hermes/plugins/outbox`) rewrites an attachment the gateway would
drop (a refused place, a missing file; not a remote image, nor an example in
code or a quote) into a sentence saying it was not sent, before the reply
reaches the user and the transcript. It reports rather than moves the file: the directories it names are
refused because credentials live there.

## Auto-review of Hermes' actions

The `guard` plugin (`modules/hermes/plugins/guard`), always installed,
reviews every action Hermes is about to take, but reads (files, searches, tool
searches, the read-only MCP servers, screenshots; opening a web page is reviewed,
its address can carry data out). It fails closed: without a decision model
(`server.hermes.decision.approval` off), every such action waits for your yes
in Telegram, on an approval card whose reason reads `no decision model
configured: ` and the action. With it on (the bootstrap's Models section;
Baseten's mammoth-1 by default), a decision model rates two
things at once, as Codex's automatic approval review does: how clearly your own
messages authorize the action, and how risky it is. Low risk (a click that
navigates, a draft) runs at once, bounded risk when you asked for it, and high
risk (a send, a post) only when you asked for that exact action; anything else,
and anything critical, waits for your yes in Telegram, through Hermes' own approval
gate (a no, or no answer, refuses it): a card with Once, Session, Always and Deny
buttons, whose reason line shows the action (the command, or the tool's
arguments, cut to fit the card and with credentials masked). So does any error of the model: nothing
is refused outright, nothing unclear runs. A short answer ("oui") is read with
Hermes' question it answers. The review replaces computer_use's own question
for each click or key (the `cua` server's clicks are reviewed like any tool),
so one action asks at most once.

As in Claude Code's auto mode, the reviewer sees your messages and Hermes'
actions, never what the tools returned: a WhatsApp message, an email or a web
page telling Hermes to act cannot argue with it. Only Telegram turns count as
yours (Telegram answers its owner only), and so does a message you send in the
middle of one (it reaches the turn as a row only Hermes writes); a turn the events daemon starts, about
an incoming message, authorizes nothing, and neither does a notice the gateway
posts in your chat itself (a background process or a subagent finishing, a
watch pattern matching). Hermes' own checks stay underneath:
its pattern-matched dangerous commands, and its hardline blocklist.

The same review answers what a sandboxed Pi session asks Hermes for (a host
its grants do not cover, a folder of this Mac, a push, a command here;
[sandbox.md](sandbox.md)); a command here always comes to you. Nothing inside the VM is
approved: Pi runs its own commands freely there. Pi asks Hermes for access,
and Hermes' approval system decides as for one of its own tool calls: the
decision model reviews the request against your messages from when Hermes
started the session, never Pi's, and what it does not clear comes to you as
buttons. Without a decision model, every such request comes to you.

A subagent (`delegate_task`) is reviewed with its parent's messages. When
its action needs your yes after its parent's turn ended (a background
subagent usually does), Hermes' card has no turn to post in, and its gate
would refuse the action without asking anyone; guard asks you instead, with
`owner_approval`'s buttons in the main chat: Allow once, Allow for this
session, Deny.

Every question Hermes asks you has buttons. Its own belong to a turn: its
approval card and the `clarify` tool's choices are buttons in the chat the
turn runs in (its instructions say to ask with `clarify`, not in a reply),
and the events' proposals are buttons in the main chat (docs/events.md). A
plugin that must ask you outside any turn, as the sandbox does for a request
its guest makes, uses the `owner_approval` plugin
(`modules/hermes/plugins/owner_approval`; its Python API is in its
docstring): a message with buttons in the main chat that only you can
answer, edited to show your answer, and refused when you do not answer in
time, or when Telegram is not connected.

iMCP's own Reminders, Notes and Messages services stay off (Nix sets them, with
Hermes trusted as a client and its self-updates off): the skills do more there.
The skills' permissions belong to `/Library/Hermes/hermes-launcher`, which
starts the gateway, so they hold across Hermes updates. A revoked one: run the bootstrap
again over SSH, looking at the Mac.

## Coding tasks in a sandbox

With `server.hermes.sandbox.enable` (the bootstrap asks, in its Coding agent
section), Hermes can hand a coding task on one of your git repositories to Pi,
another coding agent, in a microVM: `sandbox_run` copies one ref in as a git
bundle, Pi works there with no access to this Mac, no secret (its provider's
key is swapped in by the host, for that provider's hosts only) and no network
but its model, and `sandbox_result` reads its branch from a review clone where nothing
it wrote can run. When Pi needs another host, it asks Hermes for access and
Hermes' approval system decides: the auto-review, or your buttons (Once, this
method and path, the whole host, Deny; no answer refuses). Pi may also ask,
with typed actions only, for a read-only copy of a folder, a push of its
branch, your answer to a question, or a command here (always your buttons).
You take the branch with `git fetch`, after reading it. The
details: [sandbox.md](sandbox.md).

## The Hermes app

With `server.hermes.app.delivery.enable`, Hermes builds its iPhone and iPad
app on this Mac, signs it with your Apple Account (a free one works) and
installs it on your devices over Wi-Fi: `app_devices` lists them,
`app_install` rebuilds and installs (after a new pet, or when you ask), and a
launchd job re-signs it before its 7-day profile expires. Details:
[app.md](app.md).

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
| Instagram | instagram.com in Hermes' always-open Google Chrome (no API exists for a personal account; `modules/hermes/agent/browser.nix`): one persistent profile (`~/.hermes/browser-profile`), DevTools on loopback for Hermes' browser tools and the events daemon; the `instagram` skill, whose DM code (`direct.js`) runs inside the page itself — it reads the inbox out of the app's own traffic and writes with the app's own message box, so no endpoint is hand-called and no client is unofficial | your first login, on the Mac's screen |
| Discord | discord.com in the same Chrome (no API for a user account); the `discord` skill reads and sends, and the events daemon keeps a Discord tab open for its notifications | your first login, on the Mac's screen |
| 1Password | a service account reading one vault (`server.hermes.onepassword.vault`, "Hermes"): `browser_vault` fills its Login items into pages without the model seeing them; `server.hermes.onepassword.env` maps variables to `op://` references | its token, into the secrets file |

For Instagram and Discord, put a Login item each in that vault with the
website `https://www.instagram.com` or `https://discord.com` (the page's origin must match exactly), your
username and password, and its one-time password if you use two-factor
authentication: Hermes logs in again by itself when the session ends.

WhatsApp, Instagram and Discord all act as you, through clients their terms do not
allow (an unofficial linked device, an automated browser): they may restrict
an account that behaves like a bot. The skills tell Hermes to go at a person's
pace and to confirm before it sends or posts anything, always with buttons:
guard's approval card is the question, with or without a decision model
(`modules/hermes/agent/skills/confirm.nix`).

## Models

- A chain, chosen by the bootstrap (or set in `hosts/local.nix`): the main model
  (`server.hermes.model`), then its fallbacks in order (`server.hermes.fallbacks`),
  then, only if `server.hermes.localFallback` is on, the local model. When one
  fails (a limit reached, an outage, an expired login, no funds left), Hermes
  goes on with the next for that turn, and tries the main one again on the next
  turn ([Hermes' fallback
  providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers)).
  For example: OpenCode Go's DeepSeek, then your ChatGPT subscription.
- A fallback is the model used least, so the one whose failure goes unseen:
  keep in the chain only what still has funds or quota. On Nov 6, 2026 the
  ChatGPT plan's limit was reached (Hermes waited ~20 days to retry it) and
  OpenCode Zen had no funds left, so every turn went to the local model, which
  took 5 to 95 minutes a turn on the main chat's prompt: `localFallback` is off
  by default since.
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
- Local, a choice of the bootstrap (`server.uzu.enable`, `server.uzu.model`):
  uzu serves one of the models of `pkgs/uzu-models.nix` that fits the Mac (Qwen
  3.5 9B on 16 GB) on the GPU at `127.0.0.1:8000`, for the events' screening
  and the sub-chats that pin `uzu:local`; none at all is fine. Compactions can use it
  too: `server.hermes.memory.compactionModel = "uzu:local"`. Its files are pinned
  by revision in `pkgs/uzu-models.nix`, without the speculator: Trymirai's
  registry otherwise serves a new revision at any start, and the one of Oct 30,
  2026 made uzu panic on M1 to M4 GPUs (its speculator needs an M5's MXU). A new
  model, or a new uzu, comes with a new entry there, tried on an M1 to M4 first.

## Speed: the prompt is what a step costs

A turn is one call to the model per tool call, and every call re-sends the
conversation. DeepSeek V4.1 Flash on OpenCode Go answers a ~70k-token prompt in
4 to 6 s (80 to 100% of it cached). Steps of 24 to 31 s on Nov 6, 2026 were
not the prompt: 20 s of each was unii waiting for summaries that kept failing
(their provider was out of funds; a step now waits 3 s at most, only at a
turn's start, never for a failed one), and a screenshot read cost ~50 s of
thinking (`auxiliary.vision.reasoning_effort = "none"` now, in
`modules/hermes/agent/model.nix`). Turns of 5 to 95 minutes were the local
model answering for the chat after every remote model had failed ("Models").
Tool output is still what fills the prompt (a `cua` script result, a terminal
dump, a whole skill re-read).

`modules/hermes/agent/context.nix` keeps it down with Hermes' deterministic
prune: past 24k tokens of re-sent history, oversized tool results outside the
newest ten messages become a summary, with no model call and no deletion —
the transcript keeps everything, and `session_search` reaches it. It commits
only when it reclaims 4k tokens, so the prompt cache is not broken every turn.

What the model can do from its side is in the prompt: several commands in one
call, independent calls in one message, no second `skills_list`.

## The main chat is a front desk

A chat is one queue: while a turn runs, what you send waits for it. A turn
that watched a build for hours left every message unanswered for hours, and
on an ordinary day messages waited 1 to 10 minutes. So the main chat only
answers and dispatches; anything longer runs in a background subagent
(`delegate_task`, whose top-level calls answer at once and post their result
as a new message). The prompt says so, and the `front_desk` plugin
(`modules/hermes/plugins/front_desk`) enforces it:

- A turn of the main chat may make 8 tool calls or run 2 minutes
  (`server.hermes.frontDesk`; the time spent waiting on your answer, an
  approval card or a question, not counted). Past that, its tool calls are
  refused, and the refusal tells Hermes to hand the rest to `delegate_task`
  with the whole context, say what it launched, and end the turn. What stays
  open: `delegate_task`, questions and messages to you, memory and recall,
  finding a tool, and checking on or stopping a background command.
- A foreground command that may run more than a minute (a longer timeout, a
  build, a rebuild, an install, a test run, a long `sleep`) runs in the
  background instead and notifies when it exits: its result is a new message.

Only the main chat's own turns: a subagent works as long as it needs (it is
neither capped nor its commands moved, and it waits for its own builds), and
so do the sub-chats, the events' turns, cron and the CLI. A subagent's actions
are reviewed by guard as its parent's would be, with the parent's messages,
and what guard does not clear comes to you as an approval card, as in the
main chat.

## A rebuild in the middle of a turn

`server-rebuild` restarts the gateway whenever its configuration changes
(`modules/hermes/agent/session/restart.nix`). On SIGTERM it stops the turn in
flight, gives it up to 45 s to settle as *interrupted*, and starts again; the
messages queued behind it then run in order, and the stopped one is not re-run
(send it again if it still matters). launchd allows the gateway 60 s for that
(`ExitTimeOut`; its default of 20 s killed it first), and the rebuild waits for
the old gateway to be gone before it starts the new one.

A rebuild is not what paused the chat on 2026-11-06, though. A heavy build
Hermes ran from the chat (a Metal shader compile) saturated the machine. The
gateway was a `Background` launchd process, as upstream ships it, so it was
limited to the efficiency cores at priority 4, and so was every command it
ran. Its event loop starved, Telegram timed out, and its loop watchdog killed
it some 25 minutes later. The next start, starved the same way, took 15 minutes.
Now the gateway runs `Interactive`, as an app does, and every command Hermes
runs (`bash -c`, and `$SHELL -lic` for a background process) starts under
`taskpolicy -c utility` (`modules/hermes/agent/tools.nix`). The children
inherit that, so on a busy machine the gateway is served first, while an idle
one still runs commands at full speed.

A turn that was killed rather than stopped (a crash, a power loss, a stop that
overran the 60 s) is one Hermes cannot tell finished or not: it marks it
`unknown`. Upstream then pauses the chat behind it until you send `/discard`
(it settles on its own only a turn nobody sent: a cron run, an event, a
webhook). Here the `lost_turns` plugin (`modules/hermes/plugins/lost_turns`)
settles your own Telegram turn the same way `/discard` would, so you never
have to: as the gateway starts, before Telegram connects, and again before
any message of yours, if a turn was lost while it kept running or the start
has not reached it yet, so you never get the "send /discard" notice. The lost turn
is not re-run; it ends in the transcript with a notice that it was cut off, so
Hermes knows it stopped half-way and checks where the work stands before it
carries on. The messages you sent meanwhile then run in order. When you sent
nothing meanwhile, Hermes gets one turn of its own to pick the work up or tell
you where it stopped (a `[SYSTEM: …]` turn, so the auto-review treats its
actions as not asked by you). If that turn is lost too, Hermes settles it
itself and does not try again.

Other chats (a group, another platform) still pause as upstream does: send
`/discard` there, or, from a shell on the server as Hermes while the gateway
runs, `hermes sessions discard <session> --yes`.
