# Restart the gateway whenever its configuration changes. launchd.nix restarts
# an agent only when its definition changes, and config.yaml, .env, the
# documents and the plugins live outside it; a fingerprint of them in the
# definition makes any change to them a change to it. (Secrets are read from
# a file outside the store: a new secret alone still needs a restart by hand.)
{ config, lib, ... }:
let
  cfg = config.services.hermes-agent;
  fingerprint = builtins.hashString "sha256" (builtins.toJSON {
    inherit (cfg) settings environment documents hermesHomeFiles mcpServers extraPlugins;
  });
in
{
  launchd.agents.hermes-agent.config.EnvironmentVariables.HERMES_CONFIG_FINGERPRINT = fingerprint;
}
