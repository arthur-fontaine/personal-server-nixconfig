# The agent's prompts. SOUL.md is UniiChat's turn prompt (section 5 of
# https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449, Unii
# renamed Hermes, the paragraph on computers replaced by one on sub-chats).
# AGENTS.md is the user's instructions that follow it, filled in from the
# options.
{ server, hostName, ... }:
let
  cfg = server.hermes;
  agents = builtins.replaceStrings
    [ "@admin@" "@agent@" "@remote@" "@nixconfigDir@" "@host@" "@model@" "@uzuPort@" ]
    [
      server.admin.user
      cfg.user
      server.nixconfig.remote
      server.nixconfig.dir
      hostName
      "${cfg.model.name} (${cfg.model.provider})"
      (toString server.uzu.port)
    ]
    (builtins.readFile ./AGENTS.md);
in
{
  services.hermes-agent = {
    hermesHomeFiles."SOUL.md" = ./SOUL.md;
    documents."AGENTS.md" = agents;
  };
}
