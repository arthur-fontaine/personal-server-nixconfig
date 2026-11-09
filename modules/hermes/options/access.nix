{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes.access = {
    freezeAfter = mkOption {
      type = types.ints.positive;
      default = 24 * 60 * 60;
      description = "Seconds after which a file Hermes created can no longer be written or deleted by it.";
    };
    launcher = mkOption {
      type = types.str;
      default = "/Library/Hermes/hermes-launcher";
      description = ''
        A fixed path for tcc-launcher (pkgs/tcc-launcher), the parent of the
        gateway, fsearch and hermes-freeze. Full Disk Access is granted to it
        once; it is rewritten only when its own version changes, never when
        Hermes updates.
      '';
    };
    scanInterval = mkOption {
      type = types.ints.positive;
      default = 300;
    };
    space = {
      noticeBytes = mkOption {
        type = types.ints.positive;
        default = 1024 * 1024 * 1024;
        description = ''
          A folder of Hermes' (two levels under its home, /Users/Shared or a
          temp folder) holding at least this many bytes it created is named to
          it at its next turn when its first file freezes within `noticeWindow`
          (plugins/space), so it deletes what is scratch while it still can.
        '';
      };
      noticeWindow = mkOption {
        type = types.ints.positive;
        default = 3 * 60 * 60;
        description = "Seconds before the freeze that a big folder is named to Hermes.";
      };
      weeklyThreshold = mkOption {
        type = types.ints.positive;
        default = 20 * 1024 * 1024 * 1024;
        description = ''
          Bytes of frozen leftovers in the Hermes home (files it created, now
          yours, still on disk) past which you get one Telegram line on Monday
          morning. Nothing is ever deleted for you.
        '';
      };
    };
    mutablePaths = mkOption {
      type = types.listOf types.str;
      default = [
        ".hermes"
        ".cache"
        ".config"
        ".local"
        ".nix-profile"
        ".nix-defexpr"
        ".npm"
        ".cua-driver"
        "Library"
        # home-manager links the agent's apps here.
        "Applications"
        # Generated from this repository at each activation.
        "workspace/AGENTS.md"
      ];
      description = ''
        Paths in the Hermes home (relative) that hold its own runtime state,
        or files activation regenerates, and stay writable: memory, sessions,
        caches, installed software. Everything else it creates freezes.
      '';
    };
  };
}
