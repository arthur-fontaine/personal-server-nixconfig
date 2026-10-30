# Decision models: models answering System One (POST /v1/systemone) with
# probabilities over the options they are given, instead of text. TypeSafe's
# Jev, Baseten's elephant-1 and mammoth-1, or a local one swap by the same four
# values, one model per use:
# - computerUse: picks each action of browser_fast_act (agent/fast-act.nix);
# - approval: reviews each action Hermes is about to take (plugins/guard).
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
        user's own messages only: what it finds both low-risk and asked for
        runs, everything else waits for the user's yes in Telegram.
      '';
    };
  };
}
