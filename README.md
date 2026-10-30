# personal-server-nixconfig

A declarative macOS server for an old M1 Pro MacBook: nix-darwin and
home-manager, nothing installed by hand. It runs one thing well, a
[Hermes Agent](https://github.com/NousResearch/hermes-agent) you talk to on
Telegram, with local models served by [uzu](https://github.com/trymirai/uzu).
The layout follows [arthur-fontaine/nixconfig](https://github.com/arthur-fontaine/nixconfig).

## What it sets up

- **Hermes, configured from scratch** (no `hermes setup`), as its own macOS
  account, on a chain of models you choose: for example your ChatGPT
  subscription, then OpenCode Zen's DeepSeek, then the local model, each taking
  over when the one before fails.
- **One chat that never ends**: your Telegram DM with the bot is the main chat,
  with UniiChat-style memory instead of sessions and compaction.
- **Sub-chats**: topics the bot opens in that DM (`/sub new`), and any group
  with the bot, each with its own rules for memory access, shared memory
  volumes, tools, expiry, encryption and model.
- **Hermes writes first**: a message, a notification or a change at home that
  may call for you is screened by the local model, looked into (your calendar,
  the place), and turned into a proposal in the main chat
  ([`docs/events.md`](./docs/events.md)).
- **Access rules enforced by macOS**: it reads anything, writes only what it
  created in the last 24 hours, and changes the machine only by pushing to this
  repository.
- **Apple's apps**: iMessage, Notes, Reminders, Find My, Calendar, Contacts,
  Mail, Maps, Music, Shortcuts… on your Apple Account (the Apple skills and
  [iMCP](https://github.com/mattt/iMCP)).
- **Integrations, each optional**: WhatsApp, Instagram, Discord, Home
  Assistant, HomeKit, 1Password, RunPod, GitHub notifications.
- **Tools**: computer use (Accessibility + Screen Recording), its own always-open
  Chrome, fsearch (files by name), DigUp (files by content), and any software
  through Nix.
- **uzu**: Qwen 3.5 9B on the GPU: the last fallback, the events' screening,
  and private or temporary sub-chats.
- **A server Mac**: SSH with keys only, never sleeps, restarts itself, the
  display awake but unlit, Spotlight, Bluetooth and Siri off, Low Power Mode.

## Install

On the server, from a terminal:

```sh
tmp="$(mktemp -t bootstrap.XXXXXX.sh)" &&
curl -fsSL https://raw.githubusercontent.com/arthur-fontaine/personal-server-nixconfig/main/scripts/bootstrap-macos.sh -o "$tmp" &&
chmod +x "$tmp" && "$tmp"
```

It installs Nix, clones this repository to `~/personal-server-nixconfig`, asks
for your SSH keys, your models and the integrations you want with their keys,
switches to the configuration, then sets up the Hermes account's login, GitHub
access, your Telegram bot and the macOS permissions, then reboots. Run it once
more over SSH while you look at the Mac
(`~/personal-server-nixconfig/scripts/bootstrap-macos.sh`): that run signs
Hermes in to your Apple Account, logs it in to Instagram and Discord if you
chose them, and checks the whole chain. [`MANUAL_SETUP.md`](./MANUAL_SETUP.md)
lists each step and the few clicks only you can make.

## Changing it

Edit, commit, push to `main`, then on the server:

```sh
sudo server-rebuild
```

Hermes does the same for any change you ask of it, a Cloudflare tunnel as much
as its own settings. Host-specific values (SSH keys, the models, the
integrations, ...) go under
`server = { ... };` in `hosts/shared.nix` or a git-ignored `hosts/local.nix`
(see `hosts/local.nix.example`).

## More

- [`docs/hermes.md`](./docs/hermes.md): the single chat, sub-chats, what Hermes may touch
- [`docs/events.md`](./docs/events.md): Hermes writing first, when a message may call for you
- [`docs/repository-layout.md`](./docs/repository-layout.md): where things are, and the checks
- [`docs/uninstall.md`](./docs/uninstall.md): disabling Hermes, removing it, or uninstalling everything (`scripts/uninstall-macos.sh`)
- [`modules/hermes/plugins/unii/README.md`](./modules/hermes/plugins/unii/README.md): the memory plugin and its sources
- [`AGENTS.md`](./AGENTS.md): for coding agents working on this repository
