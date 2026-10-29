{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes.homeassistant = {
    url = mkOption {
      type = types.str;
      default = "http://homeassistant.local:8123";
      description = "Home Assistant's address, as this Mac reaches it. The bootstrap asks for it.";
    };
    watchDomains = mkOption {
      type = types.listOf types.str;
      default = [ "lock" "alarm_control_panel" "binary_sensor" "person" ];
      description = ''
        The domains whose state changes are events (doors, motion, locks, the
        alarm, who is home); the rest stays quiet. Hermes still reads and
        controls every device.
      '';
    };
    watchEntities = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "sensor.washing_machine_status" ];
      description = "Single entities whose changes are events too, whatever their domain.";
    };
  };
}
