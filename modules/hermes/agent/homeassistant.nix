# Home Assistant, when that integration is on: Hermes' official plugin for
# its tools (ha_list_entities, ha_get_state, ha_list_services,
# ha_call_service), with the token (HASS_TOKEN) in the secrets file. Its
# gateway platform stays off: the events daemon watches Home Assistant itself
# (hermes_events/homeassistant.py), so state changes are screened and
# proposed like every other event.
{ lib, pkgs, server, ... }:
lib.mkIf server.hermes.integrations.homeassistant.enable {
  services.hermes-agent = {
    extraPlugins = [ pkgs.hermes-homeassistant ];
    environment.HASS_URL = server.hermes.homeassistant.url;
    # Listed in plugins.enabled by memory.nix, which holds that list.
    settings.platforms.homeassistant.enabled = false;
  };
}
