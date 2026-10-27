# The main model on OpenCode Zen, and the on-device uzu server as a second
# provider for the sub-chats that pin it (`model = "uzu:local"`).
{ server, ... }:
let
  cfg = server.hermes;
in
{
  services.hermes-agent.settings = {
    model = {
      provider = cfg.model.provider;
      default = cfg.model.name;
    };

    providers.uzu = {
      name = "uzu (on this Mac)";
      api = "http://127.0.0.1:${toString server.uzu.port}/v1";
      transport = "chat_completions";
      default_model = server.uzu.model;
      discover_models = false;
    };
  };
}
