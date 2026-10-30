# Working on this repository

A nix-darwin + home-manager flake for one macOS server (an M1 Pro MacBook)
that runs a Hermes Agent as its own macOS account. Read `README.md`, then
`docs/repository-layout.md` for where things are; `docs/hermes.md`,
`docs/events.md` and `MANUAL_SETUP.md` describe what each part does.

This file is for coding agents changing the repository. It is not the
`AGENTS.md` Hermes reads on the server: that one is generated from
`modules/hermes/agent/prompt/agents.nix`.

## Never apply it here

The machine you work on is not the server. Never run `darwin-rebuild`,
`server-rebuild` or the bootstrap here, and never change this Mac's settings.
The user applies changes on the server (`sudo server-rebuild`, or
`scripts/bootstrap-macos.sh` for what Nix cannot do). Check your work by
evaluating and building instead:

```sh
nix eval .#darwinConfigurations.Personal-Server.config.system.build.toplevel.drvPath
nix build --no-link .#darwinConfigurations.Personal-Server.config.system.build.toplevel
nix build --no-link .#checks.aarch64-darwin.{unii,events,freeze}
```

- A new file is invisible to the flake until Git knows it: `git add -N <file>`.
- An optional part must build both off and on. Turn it on without touching
  `hosts/` with `extendModules`:
  `nix build --impure --expr '((builtins.getFlake (toString ./.)).darwinConfigurations.Personal-Server.extendModules { modules = [ { server.hermes.integrations.homeassistant.enable = true; } ]; }).config.system.build.toplevel'`
- Read what a module renders (`nix eval --json …settings…`, or `--raw` for
  the generated `AGENTS.md`) rather than assuming.

## Hermes is pinned: read its source, not your memory

Hermes' docs and code at the pinned revision are in the flake input:

```sh
src="$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.hermes-agent.outPath')"
ls "$src/website/docs"   # user-guide/, integrations/, reference/
```

Its interpreter (`hermes.hermesVenv` in `checks/default.nix`) is the one the
plugin, the events daemon and their tests run with.

Things that bit before:
- `services.hermes-agent.settings` merges attribute sets but not lists: a
  list defined in two modules keeps one. `plugins.enabled` is defined once,
  in `modules/hermes/agent/memory.nix`.
- `config.yaml` lands in the Nix store, readable by every user: secrets go
  in `/etc/hermes/secrets.env` (environment variables), never in settings.
- In Nix, `f "x" + "y"` is `(f "x") + "y"`: parenthesize a string you build
  before passing it.

## Rules the server enforces

- Secrets live only in `/etc/hermes/secrets.env` (written by the bootstrap,
  read by Hermes and the events daemon). `hosts/local.nix` (git-ignored)
  holds this host's choices: SSH keys, models, integrations, addresses.
- The Hermes account writes only what it created in the last 24 hours
  (`modules/hermes/system/access`): anything it must keep writing lives under
  a mutable path (`server.hermes.access.mutablePaths`: `~/.hermes`,
  `~/.local`, `~/Library`…), never `~/.something` of a tool's choosing.
- macOS permissions (Full Disk Access, Reminders, Automation…) belong to
  `/Library/Hermes/hermes-launcher`, which starts the gateway and the daemons:
  run what needs them under it.
- External services are integrations (`server.hermes.integrations`), off by
  default; their skills, MCP servers, event sources, prompt lines and
  bootstrap steps follow the switch. Apple's apps are not integrations.

## The bootstrap

`scripts/bootstrap-macos.sh` runs on a fresh Mac, so under macOS' bash 3.2
(`set -euo pipefail`): no associative arrays, no empty array expanded under
`set -u` (use `${a[@]+"${a[@]}"}`), and no `x="$(cmd)"` whose cmd may fail
(add `|| true`). It installs Nix and clones the repository, then sources
`scripts/bootstrap/lib.sh` and each section of `scripts/bootstrap/` in the
order it lists; an integration's setup is its own file in
`scripts/bootstrap/integrations/`, starting with `integration_on <name> ||
return 0`. A new step goes in the section it belongs to, after its `step`
title: every section prints its title, and a part already set up says so with
`keep "<summary>"`, which asks "Change it?". Anything that writes
`hosts/local.nix` (`set_host`) runs before `system.sh` applies the
configuration; anything that needs Hermes' account, after.

Test sections by sourcing `lib.sh` and them, in that order, from a script that
stubs `sudo`, `gum`, `nix`, `curl`, `id` and `launchctl` (and puts fake `gh`,
`wacli`… first on `PATH`), and run it with `/bin/bash`, both as a first run
and as a re-run answering No to every "Change it?"; test network checks
against a small local server.

## Changing things

- One logical change per commit, committed as soon as it works, with
  Conventional Commits (`feat(hermes): …`, `fix(scripts): …`). Commits are
  signed through 1Password; when signing fails, commit with `--no-gpg-sign`
  and tell the user. Never push unless asked.
- Package what nixpkgs lacks in `pkgs/` from a pinned release or commit, and
  name the source in a comment. Signed macOS binaries and apps are copied
  as they are (`dontFixup`), never rewritten.
- Comments say why, not what; link the upstream file or doc a decision rests
  on, at a pinned revision when possible.
- Update the docs in the same change: the step table in `MANUAL_SETUP.md`,
  `docs/*.md`, and the generated prompt (`agents.nix`) when Hermes should
  know.
- Tests poll for what they wait on: fixed sleeps fail on a loaded machine.
- Clean up what only served a test (scratch files, temporary homes, test
  browsers) before you finish.
