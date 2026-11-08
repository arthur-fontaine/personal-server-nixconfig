# Hermes changes the system through this repository: it pushes a commit, then
# `sudo server-rebuild` pulls it into the administrator's checkout and applies
# it. Whoever can push to the repository can therefore change the whole
# machine, Hermes included.
#
# A few of its own settings it may also change without a push, in
# ~/.hermes/local/overrides.json: server-rebuild checks that file as root
# (./overrides/overrides.py: MCP servers, skills, enabled plugins' settings,
# models; nothing else, the whole file refused otherwise), places it in the
# checkout (hosts/hermes-overrides.json, git-ignored), keeps each version,
# tells the owner on Telegram what changed, then applies.
{ config, lib, pkgs, hostName, ... }:
let
  hermes = config.server.hermes;
  hm = config.home-manager.users.${hermes.user}.services.hermes-agent;
  # What the checker needs from the repository: never overridable locally.
  policy = pkgs.writeText "hermes-overrides-policy.json" (builtins.toJSON {
    enabled_plugins = hm.settings.plugins.enabled or [ ];
    repo_mcp_servers = lib.attrNames hm.mcpServers;
    hermes_home = "${hermes.home}/.hermes";
  });
  checker = pkgs.writeShellScript "hermes-overrides" ''
    exec ${pkgs.python3}/bin/python3 -I ${./overrides/overrides.py} "$@"
  '';
  server-rebuild = pkgs.writeShellScriptBin "server-rebuild" ''
    export DIR=${lib.escapeShellArg config.server.nixconfig.dir}
    export HOST=${lib.escapeShellArg hostName}
    export HERMES_USER=${hermes.user}
    export OVERLAY=${hermes.home}/.hermes/local/overrides.json
    export LOCAL_SECRETS=${hermes.home}/.hermes/local/secrets.env
    export STATE=/var/db/hermes-overrides
    export SECRETS=${lib.escapeShellArg hermes.secretsFile}
    export ENV_OUT=${lib.escapeShellArg hermes.localOverrides.secretsFile}
    export POLICY=${policy}
    export CHECK=${checker}
    export GIT=/run/current-system/sw/bin/git
    export DARWIN_REBUILD=/run/current-system/sw/bin/darwin-rebuild
    export CURL=/usr/bin/curl
    # Over HTTPS, as cloned: a ~/.gitconfig rewriting GitHub URLs to SSH would
    # need the administrator's key, which may be in 1Password, out of reach here.
    export AS_ADMIN="/usr/bin/sudo -u ${config.server.admin.user} -H GIT_CONFIG_GLOBAL=/dev/null"
    export AS_HERMES="/usr/bin/sudo -u ${hermes.user} -H"
    exec ${pkgs.bash}/bin/bash ${./overrides/server-rebuild.sh} "$@"
  '';
in
{
  environment.systemPackages = [ server-rebuild ];

  security.sudo.extraConfig = lib.mkIf hermes.enable ''
    ${hermes.user} ALL=(root) NOPASSWD: /run/current-system/sw/bin/server-rebuild
  '';
}
