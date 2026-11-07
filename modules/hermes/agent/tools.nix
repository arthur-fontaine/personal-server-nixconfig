# What the agent can run. Anything else it installs itself, with Nix: into its
# own profile for a quick need (`nix profile install nixpkgs#<pkg>`), or into
# this repository for good (prompt/AGENTS.md).
{ config, lib, pkgs, server, ... }:
let
  home = server.hermes.home;
  tools = with pkgs; [
    fsearch
    digup
    # Hermes' Apple skills: iMessage, Reminders, Notes, Find My.
    imsg
    remindctl
    memo
    peekaboo
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

  # Every command Hermes runs starts through one of these: the terminal
  # tool's `bash -c` (the first bash on PATH: tools/environments/local.py,
  # _find_bash) and a background process's `$SHELL -lic` (_find_shell). The
  # utility QoS clamp, inherited by all its children (taskpolicy(8)), ranks
  # them below the gateway (priority 20 against 31) without leaving the
  # performance cores: an idle machine runs them at full speed, a busy one
  # serves the gateway first. A Metal or Xcode build talks to its compiler
  # services over XPC, which carries the clamp along where nice would not.
  clamped = name: shell: pkgs.writeTextFile {
    name = "hermes-${name}-utility";
    destination = "/bin/${name}";
    executable = true;
    text = ''
      #!/bin/sh
      exec /usr/sbin/taskpolicy -c utility ${shell} "$@"
    '';
  };
  commandBash = clamped "bash" "${pkgs.bash}/bin/bash";
  # The account's login shell (../system/user.nix), which launchd gives
  # its jobs as SHELL.
  loginShell = clamped "zsh" "${pkgs.zsh}/bin/zsh";
in
{
  services.hermes-agent.extraPackages = tools;

  # Without TinyFish, web search stays OpenAI's own, server-side on the Codex
  # model (Hermes picks it from the openai-codex login), but that backend
  # cannot read a page, so web_extract failed ("search-only backend").
  # Firecrawl without a key reads through Hermes' keyless free tiers
  # (website/docs/user-guide/features/web-search.md, plugins/web/firecrawl).
  services.hermes-agent.settings.web.extract_backend = "firecrawl";

  # With TinyFish, ../plugins/tinyfish (the Pi extension web, ported) answers
  # web_search with TinySearch's filters, and adds web_fetch (pages as
  # Markdown) and view_image. Its web_search replaces Hermes' own, whose
  # backends take only a query: a plugin may replace a built-in tool only
  # with this grant (hermes_cli/plugins.py, _tool_override_allowed). Listed in
  # plugins.enabled by memory.nix.
  services.hermes-agent.extraPlugins = lib.optional server.hermes.integrations.tinyfish.enable
    (pkgs.runCommand "hermes-plugin-tinyfish" { } "cp -R ${../plugins/tinyfish} $out");
  services.hermes-agent.settings.plugins.entries = lib.optionalAttrs server.hermes.integrations.tinyfish.enable {
    tinyfish.allow_tool_override = true;
  };

  # The gateway's PATH, which every terminal command inherits: the tools above,
  # then what the agent installed into its profile, then the system's.
  launchd.agents.hermes-agent.config.EnvironmentVariables.PATH = lib.mkForce (lib.concatStringsSep ":" [
    (lib.makeBinPath ([ commandBash config.services.hermes-agent.package pkgs.bash ] ++ tools))
    "${home}/.nix-profile/bin"
    "/etc/profiles/per-user/${server.hermes.user}/bin"
    "/run/current-system/sw/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/bin:/bin:/usr/sbin:/sbin"
  ]);
  launchd.agents.hermes-agent.config.EnvironmentVariables.SHELL = "${loginShell}/bin/zsh";

  # Upstream's agent is a Background process (nix/homeManagerModules.nix):
  # throttled to the efficiency cores at priority 4, as was everything it
  # ran. On 2026-11-06 a shader build from the chat saturated them, the
  # gateway's loop starved until its watchdog killed it, and the next start
  # took 15 minutes (3.6 s of CPU in 300 s). The gateway answers the user: it
  # runs as an app does, and its commands get the clamp above.
  launchd.agents.hermes-agent.config.ProcessType = lib.mkForce "Interactive";

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
