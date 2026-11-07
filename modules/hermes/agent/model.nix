# The main model, its fallbacks in order (Hermes' fallback_providers:
# https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers),
# and the on-device uzu server: the last fallback, and the provider of the
# sub-chats that pin it (`model = "uzu:local"`).
{ lib, server, ... }:
let
  cfg = server.hermes;
  # An OpenAI-compatible API, as Hermes' named providers take it:
  # https://hermes-agent.nousresearch.com/docs/user-guide/configuring-models
  named = p: {
    name = p.label;
    api = p.url;
    transport = "chat_completions";
  } // lib.optionalAttrs (p.keyEnv != null) { key_env = p.keyEnv; };
in
{
  assertions = [{
    assertion = !(cfg.providers ? uzu);
    message = "server.hermes.providers.uzu: that name is the local model's.";
  }];

  services.hermes-agent.settings = {
    model = {
      provider = cfg.model.provider;
      default = cfg.model.name;
    };

    fallback_providers = cfg.fallbacks
      ++ lib.optional (cfg.localFallback && server.uzu.enable) { provider = "uzu"; model = server.uzu.model; };

    providers = lib.mapAttrs (_: named) cfg.providers // {
      uzu = {
        name = "uzu (on this Mac)";
        api = "http://127.0.0.1:${toString server.uzu.port}/v1";
        transport = "chat_completions";
        default_model = server.uzu.model;
        discover_models = false;
        # Hermes waits up to 900s for a local endpoint's silent prefill
        # (agent.local_stream_stale_timeout), so a turn that fell back here
        # with a context too large for the on-device model hung a quarter of an
        # hour per attempt. Set on uzu alone, not that global key, so another
        # provider on the LAN or Tailscale keeps its patience; the sub-chats
        # that pin uzu:local share it. Not exactly 180: Hermes reads that value
        # as its own default and raises a local endpoint back to 900
        # (agent/chat_completion_helpers.py, _resolve_stale_timeout).
        stale_timeout_seconds = 240;
      };
    };
  };
}
