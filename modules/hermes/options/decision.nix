# Decision models: models answering System One (POST /v1/systemone) with
# probabilities over the options they are given, instead of text. TypeSafe's
# Jev, Baseten's elephant-1 and mammoth-1, or a local one swap by the same four
# values, one model per use:
# - computerUse: picks each action of browser_fast_act (agent/fast-act.nix);
# - approval: reviews each action Hermes is about to take (plugins/guard,
#   which asks the user for all of them without it).
{ lib, ... }:
let
  inherit (lib) mkOption types;

  model = defaults: types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Use it. The bootstrap turns it on with the model's key.";
      };
      url = mkOption {
        type = types.str;
        default = "https://inference.baseten.co";
        example = "https://api.typesafe.ai";
        description = "Its base URL, or its full /v1/systemone endpoint.";
      };
      model = mkOption {
        type = types.str;
        default = defaults.model;
        example = "jev-latest";
        description = "The model's id at that URL.";
      };
      authScheme = mkOption {
        type = types.str;
        default = "Api-Key";
        example = "Bearer";
        description = "The Authorization scheme before the key: Baseten's Api-Key, TypeSafe's Bearer.";
      };
      keyEnv = mkOption {
        type = types.nullOr types.str;
        default = "BASETEN_API_KEY";
        description = "The variable of the secrets file holding its key; null for a local model without one.";
      };
    };
  };
in
{
  # Claude Code's permission modes, on guard's review (plugins/guard).
  options.server.hermes.approvalMode = mkOption {
    type = types.enum [ "auto" "cautious" "ask" ];
    default = "auto";
    description = ''
      What Hermes does without asking you, beyond reading (files, searches,
      screenshots), which never asks:
      - auto: what the review model clears runs (low risk always, bounded
        risk you asked for in substance, high risk only the exact action you
        asked for); the rest asks you. As Claude Code's auto mode.
      - cautious: only what the model rates low risk runs; anything with a
        side effect asks you.
      - ask: every action asks you, and no model is called.
      Without a decision model (decision.approval off), auto and cautious ask
      for everything too: the review fails closed.
    '';
  };

  options.server.hermes.decision = {
    computerUse = mkOption {
      type = model { model = "decision-models/baseten-elephant-9b-latest"; };
      default = { };
      description = ''
        The model behind browser_fast_act, which drives Hermes' Chrome through
        Cua Driver, choosing each click and field from the page's own controls.
      '';
    };
    approval = mkOption {
      type = model { model = "decision-models/baseten-mammoth-27b-latest"; };
      default = { };
      description = ''
        The model reviewing each action Hermes is about to take, from the
        user's own messages only: what it finds low-risk runs, and riskier
        actions the user asked for (a send, only that exact one); everything
        else waits for the user's yes in Telegram. Off, the review (plugins/guard)
        stays and fails closed: every action but the read-only ones waits for
        that yes.
      '';
    };
  };
}
