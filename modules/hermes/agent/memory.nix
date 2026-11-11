# The single chat's memory is the unii plugin (../plugins/unii). Hermes' own
# memory, its distillation and its compaction are off: the view replaces them.
{ config, lib, pkgs, server, ... }:
let
  cfg = server.hermes;

  unii = pkgs.runCommand "hermes-plugin-unii" { } ''
    cp -R ${../plugins/unii} $out
  '';

  background = cfg.backgroundModel;
  compactionModel =
    if cfg.memory.compactionModel != null then cfg.memory.compactionModel
    else if background != null then "${background.provider}:${background.model}"
    else null;
in
{
  services.hermes-agent = {
    extraPlugins = [ unii ];

    hermesHomeFiles."unii/config.json" = builtins.toJSON {
      view_bytes = cfg.memory.viewBytes;
      line_bytes = cfg.memory.lineBytes;
      summary_wait_seconds = cfg.memory.summaryWait;
      compaction_workers = cfg.memory.compactionWorkers;
      compaction_model = compactionModel;
      # Empty without a local model: unii then refuses `/sub set model uzu:local`.
      uzu_model = lib.optionalString server.uzu.enable server.uzu.model;
      volumes = cfg.memory.volumes;
      presets = cfg.subchats.presets;
      default_preset = cfg.subchats.default;
      # Where AGENTS.md is: a change to it rebuilds the chat's prompt
      # (../plugins/unii/refresh.py).
      workspace = config.services.hermes-agent.workingDirectory;
    };

    settings = {
      context.engine = "unii";
      plugins = {
        # One list for every plugin: definitions of it in other modules replace,
        # not add. The Home Assistant one: homeassistant.nix.
        enabled = [ "unii" "owner_approval" "guard" "outbox" "lost_turns" "front_desk" "space" ] # owner-approval.nix, guard.nix, outbox.nix, lost-turns.nix, front-desk.nix, space.nix
          ++ lib.optional cfg.integrations.homeassistant.enable "homeassistant"
          ++ lib.optional cfg.cacheWarming.enable "cache_warm" # cache-warm.nix
          ++ lib.optional cfg.sandbox.enable "sandbox" # ../coding-agent
          ++ lib.optional cfg.sideload.enable "sideload" # ../system/sideload.nix
          ++ lib.optional cfg.app.enable "app_topic"; # app.nix
        # The compactions may run on another model than the chat.
        entries.unii.llm = lib.optionalAttrs (compactionModel != null) {
          allow_provider_override = true;
          allow_model_override = true;
        };
      };
      # Hermes' post-turn review, which writes skills, on the background model;
      # without one, "auto": the chat's own model. Never an empty block: the
      # config is merged over the existing config.yaml, so {} kept the
      # provider an older generation wrote (opencode-zen, out of funds).
      auxiliary.background_review =
        if background != null then { inherit (background) provider model; }
        else { provider = "auto"; model = ""; };
      memory = {
        memory_enabled = false;
        user_profile_enabled = false;
        nudge_interval = 0;
      };
    };
  };
}
