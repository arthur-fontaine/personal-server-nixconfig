# The review of Hermes' actions (../plugins/guard), always installed: with
# its decision model on (server.hermes.decision.approval) the model clears
# what is clearly fine; without it, guard fails closed and every action but
# the read-only ones waits for the user's yes. Listed in plugins.enabled by
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
{
  services.hermes-agent = {
    extraPlugins = [ guard ];
    # No model in it: guard asks the user for everything it would review.
    # The key is read from Hermes' environment (the secrets file) by name.
    hermesHomeFiles."guard/config.json" = builtins.toJSON ({
      timeout_ms = 10000;
      # Telegram answers its owner only (telegram.nix), so a Telegram turn is
      # the user's, and a cron job's too (its creation was reviewed); the
      # events' webhook turns are not.
      trusted_platforms = [ "telegram" "cron" ];
      mode = server.hermes.approvalMode;
    } // lib.optionalAttrs cfg.enable {
      inherit (cfg) url model;
      auth_scheme = cfg.authScheme;
      key_env = cfg.keyEnv;
    });
  };
}
