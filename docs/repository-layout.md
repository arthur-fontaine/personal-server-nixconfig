# Repository layout

One folder per feature under `modules/`, each with its own options under
`server.<feature>`, so a new feature (a tunnel, another agent, a service) is a
new folder next to them.

```
flake.nix                 darwinConfigurations, packages, checks
hosts/                    machine definitions (shared.nix, git-ignored local.nix)
pkgs/                     what nixpkgs lacks, as an overlay
checks/                   `nix flake check`: the plugin and freeze tests; hermes-turns/, end to end
scripts/                  bootstrap-macos.sh (the setup), uninstall-macos.sh (disable, remove), with gum
modules/
  system/                 the Mac itself (nix-darwin)
    options/              server.admin, server.nixconfig, server.energy
    power.nix             never sleep, restart by itself, idle power down
    ssh.nix               SSH with keys only, server.ssh.authorizedKeys
    quiet.nix             Spotlight, Bluetooth, Siri, background downloads off
    nix.nix
  hermes/                 Hermes Agent
    options/              server.hermes.*: account, model, memory, sub-chats, access
    system/               what it is to macOS (nix-darwin)
      user.nix            its own account, with home-manager
      access/             read.nix, freeze.nix (+ freeze.py), rebuild.nix, secrets.nix
      applications.nix    the apps it uses, copied into /Applications
    agent/                its home-manager configuration
      default.nix         the upstream module, from scratch, managed mode
      model.nix memory.nix telegram.nix mcp.nix tools.nix computer-use.nix
      prompt/             SOUL.md (UniiChat's prompt), AGENTS.md (this server's rules)
      session/            its GUI session: launchd agents, display, fsearch, defaults
    plugins/unii/         the single-chat memory and sub-chats (Python)
  uzu/                    local models: options, the mirai server
  home/                   the administrator's home-manager configuration
```

## Checks

```sh
nix flake check                                   # everything below
nix build .#checks.aarch64-darwin.unii            # the plugin's tests
nix build .#checks.aarch64-darwin.freeze          # what hermes-freeze picks
nix build .#darwinConfigurations.Personal-Server.system   # the whole system, without switching
nix run .#hermes-turns                            # two real Hermes turns through the memory, on a scripted model
```

## Applying

On the server: `sudo server-rebuild` pulls `main` into the administrator's
checkout and switches. With a git-ignored `hosts/local.nix`, flakes need the
`path:` reference that script uses.
