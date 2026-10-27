# Hermes on this server

## One chat that never ends

Your Telegram DM with the bot is the main chat, for daily use, forever. There
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

Each topic of your DM with the bot is a sub-chat, kept out of the main chat by
its policy: tap **+** in the chat to start one (it needs Threaded Mode, which
the setup script asks you to turn on in BotFather). A group with the bot, or a
topic of a group, is a sub-chat too. Type `/sub` in it to see its policy; the
root of the DM stays the main chat.

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
encrypted; delete the topic in Telegram to remove it), the
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

## Models

- Main: `deepseek-v4.1-flash-free` on OpenCode Zen (`server.hermes.model`).
- Local: uzu serves Qwen 3.5 9B on the GPU at `127.0.0.1:8000`
  (`server.uzu`), for the sub-chats that pin `uzu:local`. Compactions can use it
  too: `server.hermes.memory.compactionModel = "uzu:local"`.
