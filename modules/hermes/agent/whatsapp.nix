# The user's own WhatsApp, for Hermes to read and send as them: wacli
# (pkgs/wacli.nix) as a linked device, kept in sync by a daemon, and a skill
# (skills/whatsapp). The bootstrap shows the QR code that links it.
{ lib, pkgs, server, ... }:
let
  # Not ~/.wacli, its default: older files there would freeze (server.hermes.access).
  store = "${server.hermes.home}/.local/state/wacli";
  wacli = lib.getExe pkgs.wacli;
in
{
  home.packages = [ pkgs.wacli ];
  home.sessionVariables.WACLI_STORE_DIR = store;
  services.hermes-agent.environment.WACLI_STORE_DIR = store;
  services.hermes-agent.hermesHomeFiles."skills/social-media/whatsapp/SKILL.md" = ./skills/whatsapp/SKILL.md;

  # Until the device is linked there is nothing to sync: exit, and the
  # bootstrap starts it once linked. A dropped connection exits non-zero and
  # launchd restarts it.
  launchd.agents.wacli = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/sh" "-c"
        "${wacli} --json auth status | grep -q '\"authenticated\":true' || exit 0; exec ${wacli} sync --follow"
      ];
      EnvironmentVariables.WACLI_STORE_DIR = store;
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Background";
    };
  };
}
