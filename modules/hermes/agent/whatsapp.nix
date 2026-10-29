# The user's own WhatsApp, for Hermes to read and send as them: wacli
# (pkgs/wacli.nix) as a linked device, kept in sync by a daemon, and a skill
# (skills/whatsapp). The bootstrap shows the QR code that links it.
{ lib, pkgs, server, ... }:
let
  # Not ~/.wacli, its default: older files there would freeze (server.hermes.access).
  store = "${server.hermes.home}/.local/state/wacli";
  wacli = lib.getExe pkgs.wacli;
  events = server.hermes.events;
  # Each stored message posted to the events daemon (events.nix), signed with
  # the secrets file's WEBHOOK_SECRET.
  webhook = lib.optionalString (events.enable && events.whatsapp) ''
    secret="$(/usr/bin/sed -n 's/^WEBHOOK_SECRET=//p' ${server.hermes.secretsFile})"
    [ -n "$secret" ] && set -- --webhook http://127.0.0.1:${toString events.port}/whatsapp --webhook-secret "$secret"
  '';
  sync = pkgs.writeShellScript "wacli-sync" ''
    # Until the device is linked there is nothing to sync.
    ${wacli} --json auth status | grep -q '"authenticated":true' || exit 0
    set --
    ${webhook}
    exec ${wacli} sync --follow "$@"
  '';
in
lib.mkIf server.hermes.integrations.whatsapp.enable {
  home.packages = [ pkgs.wacli ];
  home.sessionVariables.WACLI_STORE_DIR = store;
  services.hermes-agent.environment.WACLI_STORE_DIR = store;
  services.hermes-agent.hermesHomeFiles."skills/social-media/whatsapp/SKILL.md" = ./skills/whatsapp/SKILL.md;

  # Unlinked, it exits, and the bootstrap starts it once linked. A dropped
  # connection exits non-zero and launchd restarts it.
  launchd.agents.wacli = {
    enable = true;
    config = {
      ProgramArguments = [ "${sync}" ];
      EnvironmentVariables.WACLI_STORE_DIR = store;
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Background";
    };
  };
}
