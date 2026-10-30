# The auto-review of Hermes' actions (../plugins/guard), when its decision
# model is on (server.hermes.decision.approval). Listed in plugins.enabled by
# memory.nix, which holds that list.
{ lib, pkgs, server, ... }:
let
  cfg = server.hermes.decision.approval;
  # The System One client, written once in fast_act.
  guard = pkgs.runCommand "hermes-plugin-guard" { } ''
    cp -R ${../plugins/guard} $out
    chmod u+w $out
    cp ${../fast-act/fast_act/decision.py} $out/systemone.py
  '';
in
lib.mkIf cfg.enable {
  services.hermes-agent = {
    extraPlugins = [ guard ];
    # Its key is read from Hermes' environment (the secrets file) by name.
    hermesHomeFiles."guard/config.json" = builtins.toJSON {
      inherit (cfg) url model;
      auth_scheme = cfg.authScheme;
      key_env = cfg.keyEnv;
      timeout_ms = 10000;
      # Telegram answers its owner only (telegram.nix), so a Telegram turn is
      # the user's; the events' webhook turns are not.
      trusted_platforms = [ "telegram" ];
    };
  };
}
