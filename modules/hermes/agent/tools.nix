# What the agent can run. Anything else it installs itself, with Nix: into its
# own profile for a quick need (`nix profile install nixpkgs#<pkg>`), or into
# this repository for good (prompt/AGENTS.md).
{ config, lib, pkgs, server, ... }:
let
  home = server.hermes.home;
  tools = with pkgs; [
    fsearch
    digup
    git
    gh
    jq
    ripgrep
    fd
    curl
    wget
    nodejs
    pnpm
    python3
    uv
    coreutils
    gnused
    gnugrep
    findutils
  ];
in
{
  services.hermes-agent.extraPackages = tools;

  # The gateway's PATH, which every terminal command inherits: the tools above,
  # then what the agent installed into its profile, then the system's.
  launchd.agents.hermes-agent.config.EnvironmentVariables.PATH = lib.mkForce (lib.concatStringsSep ":" [
    (lib.makeBinPath ([ config.services.hermes-agent.package pkgs.bash ] ++ tools))
    "${home}/.nix-profile/bin"
    "/etc/profiles/per-user/${server.hermes.user}/bin"
    "/run/current-system/sw/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/bin:/bin:/usr/sbin:/sbin"
  ]);

  programs.git = {
    enable = true;
    settings = {
      user.name = "Hermes";
      user.email = "hermes@${server.hermes.user}.local";
      # Pushes authenticate with the token `gh auth login` stored (MANUAL_SETUP.md).
      credential."https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
      init.defaultBranch = "main";
      pull.ff = "only";
    };
  };
}
