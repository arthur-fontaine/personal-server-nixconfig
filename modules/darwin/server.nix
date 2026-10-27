# The Mac is a headless, always-on server.
{ ... }:
{
  power = {
    sleep.computer = "never";
    sleep.display = 10;
    restartAfterPowerFailure = true;
    restartAfterFreeze = true;
  };

  # Remote administration over SSH (keys only).
  services.openssh = {
    enable = true;
    extraConfig = ''
      PasswordAuthentication no
      KbdInteractiveAuthentication no
    '';
  };
}
