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
  # Hermes' permission system (plugins/guard): Claude Code's auto mode,
  # ported from Arthur's Pi extension auto-mode.
  options.server.hermes.permissions = {
    defaultMode = mkOption {
      type = types.enum [ "auto" "ask" ];
      default = "auto";
      description = ''
        The mode at first start (`/mode auto|ask` changes it at runtime, kept
        in ~/.hermes/guard/mode.json):
        - auto: Claude Code's auto mode. Plainly safe calls run (reads, edits
          inside Hermes' workspace, read-only commands); every other call is
          judged by the review model (decision.approval) on the conversation
          and the call, with Claude Code's rules; a risky call is blocked and
          Hermes told why; after 3 blocks in a row or 20 in a session you are
          asked instead. Without a review model, those calls ask you.
        - ask: every call but reads asks you; no model is called.
      '';
    };
    autoMode = mkOption {
      type = types.submodule {
        options = lib.genAttrs [ "allow" "soft_deny" "hard_deny" "environment" ] (name: mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Claude Code's `autoMode.${name}`: replaces the classifier's default
            ${name} rules; the entry "$defaults" keeps them in place. Empty keeps
            the defaults.
          '';
        }) // {
          maxPromptTokens = mkOption {
            type = types.ints.positive;
            default = 14000;
            description = ''
              The most each request to the review model may take, in tokens
              counted on the safe side (3.2 bytes a token). The default leaves
              margin under mammoth-27b's 16,000, past which it refuses (HTTP 422).
              Claude Code's verbatim prompt (~30k tokens) is used only when it
              fits with room for the conversation, else a compact rewrite of the
              same rules (~9k); the conversation is cut from its oldest lines and
              AGENTS.md from its end, the action and your latest message always
              kept. An action too long to fit asks you.
            '';
          };
        };
      };
      default = { };
      example = { environment = [ "$defaults" "Trusted repo: github.com/arthur-fontaine/*" ]; };
      description = "The owner's rules for auto mode's classifier, as Claude Code's `autoMode` setting.";
    };
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
