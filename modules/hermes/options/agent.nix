{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes = {
    user = mkOption {
      type = types.str;
      default = "hermes";
      description = "The dedicated macOS account Hermes runs as.";
    };
    uid = mkOption {
      type = types.int;
      default = 550;
    };
    gid = mkOption {
      type = types.int;
      default = 550;
    };
    home = mkOption {
      type = types.str;
      default = "/Users/hermes";
    };
    secretsFile = mkOption {
      type = types.str;
      default = "/etc/hermes/secrets.env";
      description = ''
        A dotenv file, outside the Nix store and readable by the Hermes user
        only: OPENCODE_ZEN_API_KEY, RUNPOD_API_KEY, WHATSAPP_ALLOWED_USERS.
        See MANUAL_SETUP.md.
      '';
    };

    model = {
      provider = mkOption {
        type = types.str;
        default = "opencode-zen";
      };
      name = mkOption {
        type = types.str;
        default = "deepseek-v4.1-flash-free";
      };
    };
  };
}
