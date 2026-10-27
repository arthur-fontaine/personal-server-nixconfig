{ lib, username, homeDirectory, nixconfigDir, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.admin = {
    user = mkOption {
      type = types.str;
      default = username;
      description = "The human administrator. Frozen agent files are handed over to this user.";
    };
    home = mkOption {
      type = types.str;
      default = homeDirectory;
    };
  };

  options.server.nixconfig = {
    dir = mkOption {
      type = types.str;
      default = nixconfigDir;
      description = "The administrator's checkout of this repository, which `server-rebuild` applies.";
    };
    remote = mkOption {
      type = types.str;
      default = "https://github.com/arthur-fontaine/personal-server-nixconfig.git";
      description = "Where this repository lives. Hermes clones it, pushes its changes there, then asks for a rebuild.";
    };
  };
}
