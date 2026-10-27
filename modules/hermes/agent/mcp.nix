# MCP servers.
{ pkgs, ... }:
{
  services.hermes-agent.mcpServers = {
    # RunPod's hosted server (https://github.com/runpod/runpod-mcp): nothing to
    # install, and an API key instead of OAuth, which needs a browser.
    runpod = {
      url = "https://mcp.runpod.io/";
      headers.Authorization = "Bearer \${RUNPOD_API_KEY}";
    };

    # Find files by name (https://github.com/noahdunnagan/fsearch).
    fsearch = {
      command = "${pkgs.fsearch}/bin/fsearch";
      args = [ "mcp" ];
    };
  };
}
