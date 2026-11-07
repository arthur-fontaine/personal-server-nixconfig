# The prompt cache kept warm between the owner's turns (docs/hermes.md,
# "Speed"). Claude routes: Hermes' own 1-hour tier for the chats a person
# types into, 5 minutes for subagents and cron ("auto",
# website/docs/user-guide/configuration.md#prompt-caching: the 1-hour write
# costs 2x and pays off only past 5-minute pauses, which a chat has). Then
# ../plugins/cache_warm (the Pi extension cache-warmer) keeps it warm while
# the owner is idle, on Claude and OpenAI-style routes; listed in
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
        warm_hours = cfg.warmHours;
        min_ping_k = cfg.minPingK;
        daily_budget_k = cfg.dailyBudgetK;
        ttl_minutes = cfg.ttlMinutes;
        skip_providers = cfg.skipProviders;
      };
    };
  };
}
