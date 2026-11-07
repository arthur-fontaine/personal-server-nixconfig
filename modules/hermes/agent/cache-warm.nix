# The prompt cache kept warm between the owner's turns (docs/hermes.md,
# "Speed"). Claude routes: Hermes' own 1-hour tier for the chats a person
# types into, 5 minutes for subagents and cron ("auto",
# website/docs/user-guide/configuration.md#prompt-caching: the 1-hour write
# costs 2x and pays off only past 5-minute pauses, which a chat has). OpenAI-
# style routes, whose caches last minutes: ../plugins/cache_warm, listed in
# plugins.enabled by memory.nix.
{ lib, pkgs, server, ... }:
let
  cfg = server.hermes.cacheWarming;
in
{
  services.hermes-agent = {
    settings.prompt_caching.cache_ttl = "auto";
    extraPlugins = lib.optional cfg.enable (pkgs.runCommand "hermes-plugin-cache-warm" { } ''
      cp -R ${../plugins/cache_warm} $out
    '');
    hermesHomeFiles = lib.optionalAttrs cfg.enable {
      "cache_warm/config.json" = builtins.toJSON {
        inherit (cfg) interval window;
        skip_providers = cfg.skipProviders;
        max_sessions = 2;
      };
    };
  };
}
