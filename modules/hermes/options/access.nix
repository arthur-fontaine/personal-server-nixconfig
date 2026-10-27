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
