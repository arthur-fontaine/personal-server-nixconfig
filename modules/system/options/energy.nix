{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.energy = {
    lowPowerMode = mkOption {
      type = types.bool;
      default = true;
      description = "macOS Low Power Mode, on the power adapter too. Slower uzu inference, much less heat and power.";
    };
    displayBrightness = mkOption {
      type = types.numbers.between 0 1;
      default = 0.0;
      description = ''
        The built-in display stays awake (computer use needs a live screen),
        with its backlight at this level.
      '';
    };
    disableBluetooth = mkOption {
      type = types.bool;
      default = true;
    };
  };
}
