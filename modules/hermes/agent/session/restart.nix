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
  launchd.agents.hermes-agent.config = {
    EnvironmentVariables.HERMES_CONFIG_FINGERPRINT = fingerprint;
    # On SIGTERM the gateway stops the turn in flight and gives it up to 45 s
    # to settle as interrupted (TURN_SETTLE_SECONDS, gateway/run_runtime.py),
    # plus 10 s of teardown. launchd's default of 20 s killed it first: the
    # next start found the turn neither done nor stopped, fenced it `unknown`,
    # and paused the chat until /discard. 60 is the most the gui domain allows,
    # and what Hermes' own plist asks for (hermes_cli/gateway_launchd.py).
    # The gateway cannot read this budget itself (it looks only for an
    # `ai.hermes.*` label), so restart_drain_timeout stays 0: a drain would
    # come before the 45 s settle and push it past the kill.
    ExitTimeOut = 60;
  };
}
