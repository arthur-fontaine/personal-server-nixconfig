# The local overlay (../options/overrides.nix) in Hermes' settings. The
# checker let through only MCP servers the repository does not define,
# skills, enabled plugins' settings and models. Its definition comes last
# (mkAfter: the settings type folds every definition with recursiveUpdate in
# order, nix/moduleCommon.nix deepConfigType), so a value it sets wins. Lists
# are merged where they are defined once: fallbacks in model.nix, disabled
# skills in skills.nix.
{ lib, server, ... }:
let
  o = server.hermes.localOverrides.overlay;
  model = o.model or null;
in
{
  services.hermes-agent.settings = lib.mkAfter (lib.filterAttrs (_: v: v != { }) {
    mcp_servers = o.mcp_servers or { };
    model = lib.optionalAttrs (model != null) { inherit (model) provider; default = model.model; };
    agent = lib.optionalAttrs (o ? reasoning_effort) { inherit (o) reasoning_effort; };
    auxiliary = o.auxiliary or { };
    skills = lib.optionalAttrs (o ? skills.external_dirs) { inherit (o.skills) external_dirs; };
    plugins = lib.optionalAttrs (o ? plugins.entries) { inherit (o.plugins) entries; };
  });
}
