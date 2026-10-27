# Sub-chats: every WhatsApp group with the bot is one, kept out of the main
# chat according to its policy.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  policy = types.submodule {
    options = {
      memoryRead = mkOption {
        type = types.bool;
        default = false;
        description = "The sub-chat sees the main chat's memory (its view) and can zoom into it.";
      };
      memoryWrite = mkOption {
        type = types.bool;
        default = false;
        description = "The sub-chat's messages are also logged into the main chat's memory.";
      };
      volume = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          A memory volume (server.hermes.memory.volumes) the sub-chat reads
          and writes. Sub-chats naming the same volume share it, without
          touching the main memory. null: no memory beyond its session.
        '';
      };
      tools = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          The toolsets or tool names the sub-chat may use. null keeps every
          tool of the main chat. The memory tools follow memoryRead/volume.
        '';
        example = [ "web" "file" ];
      };
      ttl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          null: permanent. "session": wiped when its session ends (/new,
          /sub end). A duration ("30m", "6h", "7d"): wiped that long after its
          last message.
        '';
      };
      encrypted = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Its log is stored encrypted (AES-256-GCM, key derived from the
          passphrase of `/sub unlock`, held in memory only) and its Hermes
          transcript is scrubbed after every turn.
        '';
      };
      model = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''"<provider>:<model>", e.g. "uzu:local" for the on-device model. null: the main model.'';
      };
    };
  };
in
{
  options.server.hermes.subchats = {
    presets = mkOption {
      type = types.attrsOf policy;
      default = {
        # A side conversation that knows everything but leaves no trace.
        aside = {
          memoryRead = true;
          ttl = "session";
        };
        # Long-running work, kept apart from daily life.
        project = {
          memoryRead = true;
          volume = "projects";
        };
        # Secrets: no main memory either way, an encrypted volume, local model.
        secret = {
          volume = "vault";
          encrypted = true;
          model = "uzu:local";
          tools = [ "file" "terminal" ];
        };
        # Throwaway chat on the local model, gone an hour after its last message.
        temp = {
          ttl = "1h";
          model = "uzu:local";
          tools = [ ];
        };
      };
      description = "Named sub-chat policies, applied in a group with `/sub preset <name>`.";
    };
    default = mkOption {
      type = types.str;
      default = "aside";
      description = "The preset a new sub-chat starts with.";
    };
  };
}
