# 1Password, through a service account that reads one vault
# (server.hermes.onepassword.vault); its token, OP_SERVICE_ACCOUNT_TOKEN, is in
# the secrets file (scripts/bootstrap-macos.sh). Hermes' docs:
# https://hermes-agent.nousresearch.com/docs/user-guide/secrets/onepassword
# - browser_vault fills that vault's Login items into web pages (Instagram):
#   Hermes resolves the password and types it, the model never sees it.
# - server.hermes.onepassword.env maps variables to op:// references.
# `op` is not on the agent's PATH, so its terminal cannot read the vault.
{ lib, pkgs, server, ... }:
let
  cfg = server.hermes.onepassword;
  op = lib.getExe pkgs._1password-cli;
in
{
  services.hermes-agent.settings = {
    vault.onepassword = {
      enabled = true;
      binary_path = op;
      service_account_token_env = "OP_SERVICE_ACCOUNT_TOKEN";
    };
    # No Bitwarden here.
    vault.bitwarden.enabled = false;

    secrets.onepassword = {
      enabled = cfg.env != { };
      inherit (cfg) env;
      binary_path = op;
      # Never write resolved values to ~/.hermes/cache.
      cache_ttl_seconds = 0;
    };
  };
}
