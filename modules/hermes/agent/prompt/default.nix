# The agent's prompts. SOUL.md is UniiChat's turn prompt (section 5 of
# https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449, Unii
# renamed Hermes, the paragraph on computers replaced by one on sub-chats).
# agents.nix is the user's instructions that follow it, from the options.
{ config, lib, server, hostName, ... }:
{
  services.hermes-agent = {
    hermesHomeFiles."SOUL.md" = ./SOUL.md;
    documents."AGENTS.md" = import ./agents.nix {
      inherit lib server hostName;
      mcpServers = lib.attrNames config.services.hermes-agent.mcpServers;
    };
  };
}
