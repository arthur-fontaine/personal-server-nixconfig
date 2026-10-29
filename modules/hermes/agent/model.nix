# The main model, its fallbacks in order (Hermes' fallback_providers:
# https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers),
# and the on-device uzu server: the last fallback, and the provider of the
# sub-chats that pin it (`model = "uzu:local"`).
{ lib, server, ... }:
let
  cfg = server.hermes;
in
{
  services.hermes-agent.settings = {
    model = {
      provider = cfg.model.provider;
      default = cfg.model.name;
    };

    fallback_providers = cfg.fallbacks
      ++ lib.optional (cfg.localFallback && server.uzu.enable) { provider = "uzu"; model = server.uzu.model; };

    providers.uzu = {
      name = "uzu (on this Mac)";
      api = "http://127.0.0.1:${toString server.uzu.port}/v1";
      transport = "chat_completions";
      default_model = server.uzu.model;
      discover_models = false;
    };
  };
}
