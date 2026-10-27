# The single chat's memory: the UniiChat design (plugins/unii/README.md).
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes.memory = {
    viewBytes = mkOption {
      type = types.ints.positive;
      default = 64000;
      description = "The view shrinks to this size once it passes twice as much (UniiChat's 64-128 KB sawtooth).";
    };
    lineBytes = mkOption {
      type = types.ints.positive;
      default = 512;
      description = "The size of one summary line.";
    };
    compactionModel = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        "<provider>:<model>" for the background compactions. null: the main
        model. "uzu:local" keeps every summary on the Mac.
      '';
    };

    volumes = mkOption {
      type = types.attrsOf (types.submodule {
        options.encrypted = mkOption {
          type = types.bool;
          default = false;
          description = "Store this volume's log encrypted, unlocked with `/sub unlock`.";
        };
      });
      default = {
        projects = { };
        vault.encrypted = true;
      };
      description = "Named memory volumes that sub-chats can share.";
    };
  };
}
