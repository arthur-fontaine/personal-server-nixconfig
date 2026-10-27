# Never sleep, restart by itself, and keep idle consumption down. The display
# stays awake for computer use, with its backlight off (modules/hermes/session).
{ config, ... }:
let
  onOff = b: if b then "1" else "0";
in
{
  power = {
    sleep.computer = "never";
    # A sleeping display hands computer use a black screen.
    sleep.display = "never";
    sleep.harddisk = "never";
    restartAfterPowerFailure = true;
    restartAfterFreeze = true;
  };

  system.activationScripts.postActivation.text = ''
    echo "tuning power settings for a server..." >&2
    # disablesleep: closing the lid does not sleep the server either.
    # powernap/standby/autopoweroff/hibernatemode: no background wake-ups and
    # no RAM image written to disk. womp/tcpkeepalive: SSH and the Telegram
    # connection keep working.
    /usr/bin/pmset -a \
      disablesleep 1 \
      powernap 0 \
      standby 0 \
      autopoweroff 0 \
      hibernatemode 0 \
      proximitywake 0 \
      womp 1 \
      tcpkeepalive 1 \
      ttyskeepawake 1 \
      lowpowermode ${onOff config.server.energy.lowPowerMode} || true
  '';
}
