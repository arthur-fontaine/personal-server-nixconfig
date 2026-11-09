# Hermes' permission system (../plugins/guard), always installed: Claude
# Code's auto mode, ported from Arthur's Pi extension auto-mode. Its
# classifier is the review decision model (server.hermes.decision.approval);
# without it, auto mode asks the owner for every call its fast paths do not
# clear. Listed in plugins.enabled by memory.nix, which holds that list.
{ config, lib, pkgs, server, ... }:
let
  cfg = server.hermes.decision.approval;
  perms = server.hermes.permissions;
  # The System One client, written once in fast_act.
  guard = pkgs.runCommand "hermes-plugin-guard" { } ''
    cp -R ${../plugins/guard} $out
    chmod u+w $out
    cp ${../fast-act/fast_act/decision.py} $out/systemone.py
  '';
  # The owner's instructions, read by the classifier as Claude Code reads
  # CLAUDE.md: what they explicitly authorize may clear a soft block.
  agentsMd = pkgs.writeText "hermes-AGENTS.md" config.services.hermes-agent.documents."AGENTS.md";
in
{
  services.hermes-agent = {
    extraPlugins = [ guard ];
    # Two classifier stages with retries can outlast Hermes' 30 s hook bound,
    # after which pre_tool_call fails closed (hermes_cli/plugins.py,
    # invoke_hook): a slow model would block every reviewed call.
    settings.plugins.hook_callback_timeout = 120;
    hermesHomeFiles."guard/config.json" = builtins.toJSON ({
      timeout_ms = 20000;
      # Telegram answers its owner only (telegram.nix), so a Telegram turn is
      # the owner's, and a cron job's too (its creation was reviewed); the
      # events' webhook turns are not.
      trusted_platforms = [ "telegram" "cron" ];
      mode = perms.defaultMode;
      rules = removeAttrs perms.autoMode [ "maxPromptTokens" ];
      max_prompt_tokens = perms.autoMode.maxPromptTokens;
      identity = server.hermes.user;
      cwd = "${server.hermes.home}/workspace";
      context_file = "${agentsMd}";
    } // lib.optionalAttrs cfg.enable {
      inherit (cfg) url model;
      auth_scheme = cfg.authScheme;
      key_env = cfg.keyEnv;
    });
  };
}
