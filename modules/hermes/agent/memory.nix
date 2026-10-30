# The single chat's memory is the unii plugin (../plugins/unii). Hermes' own
# memory, its distillation and its compaction are off: the view replaces them.
{ lib, pkgs, server, ... }:
let
  cfg = server.hermes;

  unii = pkgs.runCommand "hermes-plugin-unii" { } ''
    cp -R ${../plugins/unii} $out
  '';

  compactionModel = cfg.memory.compactionModel;
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
      uzu_model = server.uzu.model;
      volumes = cfg.memory.volumes;
      presets = cfg.subchats.presets;
      default_preset = cfg.subchats.default;
    };

    settings = {
      context.engine = "unii";
      plugins = {
        # One list for every plugin: definitions of it in other modules replace,
        # not add. The Home Assistant one: homeassistant.nix.
        enabled = [ "unii" ]
          ++ lib.optional cfg.integrations.homeassistant.enable "homeassistant"
          ++ lib.optional cfg.decision.approval.enable "guard"; # guard.nix
        # The compactions may run on another model than the chat.
        entries.unii.llm = lib.optionalAttrs (compactionModel != null) {
          allow_provider_override = true;
          allow_model_override = true;
        };
      };
      memory = {
        memory_enabled = false;
        user_profile_enabled = false;
        nudge_interval = 0;
      };
    };
  };
}
