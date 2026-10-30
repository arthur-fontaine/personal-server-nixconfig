# At each login, the bootstrap's steps that need Hermes' screen are checked
# in its own session, and Terminal opens with those left to do
# (scripts/hermes-setup.sh): no SSH, no run of the whole bootstrap.
{ config, lib, pkgs, server, ... }:
let
  env = config.services.hermes-agent.environment;
  # What the steps read with `setting`, under the names the bootstrap gives
  # them (flake attribute paths), with nix eval's toString.
  settings = {
    "server.hermes.secretsFile" = server.hermes.secretsFile;
    "server.hermes.access.launcher" = server.hermes.access.launcher;
    "server.energy.displayBrightness" = toString server.energy.displayBrightness;
    "server.hermes.events.port" = toString server.hermes.events.port;
    "server.hermes.browserPort" = toString server.hermes.browserPort;
    "home-manager.users.${server.hermes.user}.launchd.agents.hermes-agent.config.EnvironmentVariables.PATH" =
      config.launchd.agents.hermes-agent.config.EnvironmentVariables.PATH;
    "home-manager.users.${server.hermes.user}.services.hermes-agent.environment.HERMES_CUA_DRIVER_CMD" =
      env.HERMES_CUA_DRIVER_CMD;
    "home-manager.users.${server.hermes.user}.services.hermes-agent.environment.WACLI_STORE_DIR" =
      env.WACLI_STORE_DIR or "";
  } // lib.mapAttrs' (name: integration: lib.nameValuePair
    "server.hermes.integrations.${name}.enable" (toString integration.enable)
  ) server.hermes.integrations;

  scripts = lib.fileset.toSource {
    root = ../../../..;
    fileset = ../../../../scripts;
  };

  run = pkgs.writeShellScript "hermes-setup" ''
    export REPO_DIR=${scripts}
    export HERMES_SETUP_SETTINGS=${pkgs.writeText "hermes-setup-settings.json" (builtins.toJSON settings)}
    export GUM=${lib.getExe pkgs.gum}
    export JQ=${lib.getExe pkgs.jq}
    export BRIGHTNESS_TOOL=${lib.getExe pkgs.display-brightness}
    export MAS_TOOL=${lib.getExe pkgs.mas}
    # macOS' own tools first: the steps use BSD stat and sed.
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    exec ${lib.getExe pkgs.bash} ${scripts}/scripts/hermes-setup.sh "$@"
  '';

  # Terminal runs a .command file it opens. (Not under timeout(1): it moves
  # the command out of the terminal's foreground, where gum could not read.)
  window = pkgs.writeScript "hermes-setup.command" ''
    #!/bin/sh
    exec ${run} window
  '';

  check = pkgs.writeShellScript "hermes-setup-check" ''
    export HERMES_SETUP_WINDOW=${window}
    exec ${run} check
  '';
in
{
  launchd.agents.hermes-setup = {
    enable = true;
    config = {
      ProgramArguments = [ "${check}" ];
      RunAtLoad = true;
      ProcessType = "Interactive";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/hermes-setup.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/hermes-setup.log";
    };
  };
}
