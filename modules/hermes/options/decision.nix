# The decision model behind fast computer use (modules/hermes/agent/fast-act.nix):
# any model answering System One (POST /v1/systemone), so TypeSafe's Jev,
# Baseten's elephant-1, mammoth-1 or joey-1, or a local one swap by these four
# values.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes.decisionModel = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Give Hermes browser_fast_act, which drives its Chrome through Cua Driver
        with this model choosing each action. The bootstrap turns it on with
        the model's key.
      '';
    };
    url = mkOption {
      type = types.str;
      default = "https://inference.baseten.co";
      example = "https://api.typesafe.ai";
      description = "Its base URL, or its full /v1/systemone endpoint.";
    };
    model = mkOption {
      type = types.str;
      default = "decision-models/baseten-elephant-9b-latest";
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
}
