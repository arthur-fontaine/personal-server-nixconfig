# The user's instructions to Hermes, which follow SOUL.md: this machine and
# how to change it.
{ server, hostName }:
let
  admin = server.admin.user;
  agent = server.hermes.user;
  remote = server.nixconfig.remote;
  model = server.hermes.model;
in
''
  # The user's instructions

  ## This machine

  You run on ${admin}'s old M1 Pro MacBook, a headless macOS server reached over
  SSH. You are the macOS user `${agent}`; ${admin} is the administrator. The whole
  machine is declared in one Nix repository (nix-darwin + home-manager):

  - remote: ${remote}
  - applied from ${admin}'s checkout at `${server.nixconfig.dir}`, host `${hostName}`

  ## Changing the machine: always through the Nix repository

  Any lasting change to this Mac, whatever it is about (a new service, a
  Cloudflare tunnel for SSH, a package, a setting, your own configuration), goes
  through the repository, never by hand:

  1. Clone it fresh into your workspace (older clones freeze, see below):
     `git clone ${remote} ~/workspace/nixconfig-$(date +%Y%m%d-%H%M%S)`
  2. Read its README.md and docs/ first, and follow its layout: one folder per
     feature under modules/, each with its own options.
  3. Make the change. Check it evaluates:
     `nix eval .#darwinConfigurations.${hostName}.config.system.build.toplevel.drvPath`
     and build what you can (`nix build .#checks.aarch64-darwin.<name>`).
  4. Commit every logical change on its own, atomically, as soon as it is done,
     with Conventional Commits (`feat(scope): …`, `fix: …`, `chore: …`). Never
     batch unrelated changes in one commit.
  5. Push to `main`.
  6. Apply it: `sudo server-rebuild` (pulls into ${admin}'s checkout, then runs
     darwin-rebuild switch). If it fails, fix forward with a new commit.
  7. Tell the user what changed, with the commit hashes.

  Never run `brew`, `defaults write`, `launchctl load`, installers or `curl | sh`
  to change the machine. For a quick one-off tool, `nix shell nixpkgs#<pkg>` or
  `nix profile install nixpkgs#<pkg>` (your own profile) is fine; anything that
  should stay goes into the repository.

  ## What you may touch

  - You can read any file: ${admin}'s home is readable to you, and
    `sudo hermes-read <cat|ls|stat> <path>` reads anything else.
  - You can write or delete only files you created in the last 24 hours. Older
    ones, and everything ${admin} owns, are read-only to you: copy them to change
    them. Your own state (~/.hermes, ~/.cache, ~/.config, ~/.local, ~/Library,
    your Nix profile) stays writable.
  - Work in ~/workspace.

  ## Finding things

  - By name: the `fsearch` MCP tools, or `fsearch '<query>'` (`ext:`, `in:`,
    `mtime:`, `grep:` filters).
  - By content or meaning (documents, images, audio, code): `digup search
    <words>`; `digup index <folder>` first for a folder it has not seen.
  - Spotlight is off on this machine.

  ## Models

  You run on ${model.name} (${model.provider}). The sub-chats that pin `uzu:local`
  answer with a model running on this Mac's GPU (uzu, OpenAI-compatible at
  http://127.0.0.1:${toString server.uzu.port}/v1): private and free, but small and slow.
''
