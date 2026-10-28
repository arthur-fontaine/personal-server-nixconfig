{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes.onepassword = {
    vault = mkOption {
      type = types.str;
      default = "Hermes";
      description = ''
        The 1Password vault Hermes' service account reads, and only that one:
        put there the logins Hermes may use (Instagram's, with its website URL
        and its one-time password). The bootstrap names it when it asks for
        the service account's token.
      '';
    };
    env = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { RUNPOD_API_KEY = "op://Hermes/RunPod/credential"; };
      description = ''
        Environment variables Hermes reads from 1Password at every start
        (op://vault/item/field), over the secrets file's.
      '';
    };
  };
}
