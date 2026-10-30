# browser_fast_act (../fast-act, fast_act): Hermes' Chrome driven through Cua
# Driver, a decision model (server.hermes.decision.computerUse) choosing each action
# from the page's own controls instead of reading screenshots. Cua's jev-use
# (libs/cua-driver/examples/jev-use) is the same loop, not yet in a release:
# once Cua Driver or Hermes ships it, this module, ../fast-act and
# ../options/decision.nix are what goes, and the OPENJEV_* settings keep their
# names.
{ config, lib, pkgs, server, ... }:
let
  cfg = server.hermes.decision.computerUse;
  hermes = config.services.hermes-agent.package;
  package = pkgs.runCommand "fast-act" { } ''
    mkdir -p $out
    cp -R ${../fast-act/fast_act} $out/fast_act
  '';
in
lib.mkIf cfg.enable {
  services.hermes-agent.mcpServers.fast-act = {
    command = "${hermes.hermesVenv}/bin/python3";
    args = [ "-m" "fast_act.server" ];
    env = {
      PYTHONPATH = "${package}";
      CUA_DRIVER_BIN = config.services.hermes-agent.environment.HERMES_CUA_DRIVER_CMD;
      FAST_ACT_CHROME_PROFILE = "${server.hermes.home}/.hermes/browser-profile";
      OPENJEV_BASE_URL = cfg.url;
      OPENJEV_MODEL = cfg.model;
      OPENJEV_AUTH_SCHEME = cfg.authScheme;
    } // lib.optionalAttrs (cfg.keyEnv != null) {
      # Hermes fills ${VAR} in from its environment (the secrets file) when it
      # starts the server: config.yaml, in the Nix store, holds only the name.
      OPENJEV_API_KEY = "\${${cfg.keyEnv}}";
    };
  };
}
