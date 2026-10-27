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
    scanInterval = mkOption {
      type = types.ints.positive;
      default = 300;
    };
    mutableDirs = mkOption {
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
      ];
      description = ''
        Directories of the Hermes home (relative paths) that hold its own
        runtime state and stay writable: memory, sessions, caches, installed
        software. Everything else it creates freezes.
      '';
    };
  };
}
