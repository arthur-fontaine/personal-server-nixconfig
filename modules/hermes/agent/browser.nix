# Hermes' browser: one Google Chrome, always open in its session, that its
# browser tools attach to (browser.cdp_url) and the events daemon watches for
# Instagram's notifications (hermes_events/instagram.py). A Google build, not
# Hermes' pinned Chrome for Testing: that one's Web Push endpoint is refused by
# Firebase (410), so sites' notifications never reach it. One profile in
# ~/.hermes (never frozen) keeps logins across restarts.
{ lib, pkgs, server, ... }:
let
  profile = "${server.hermes.home}/.hermes/browser-profile";
  chrome = "${pkgs.google-chrome}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  port = toString server.hermes.browserPort;
in
{
  launchd.agents.chrome = {
    enable = true;
    config = {
      ProgramArguments = [
        chrome
        "--user-data-dir=${profile}"
        # DevTools on loopback only, for Hermes and the events daemon.
        "--remote-debugging-address=127.0.0.1"
        "--remote-debugging-port=${port}"
        "--no-first-run"
        "--no-default-browser-check"
        # No keychain dialog nobody would answer. Cookies then use a fixed key,
        # so the profile itself is the secret: its folder is Hermes' only.
        "--use-mock-keychain"
        "--password-store=basic"
        "https://www.instagram.com/"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Interactive";
    };
  };

  services.hermes-agent.settings.browser.cdp_url = "http://127.0.0.1:${port}";

  # The browser harness writes its screenshots to ~/.config/browser-harness/tmp
  # (browser_harness/paths.py, tmp_dir), under ~/.config, which the gateway
  # refuses to deliver from (gateway/platforms/base.py,
  # _MEDIA_DELIVERY_DENIED_HOME_SUBPATHS): Hermes took screenshots it could
  # never send. The operator allowlist is checked before that denylist, so it
  # opens this one folder and nothing else of ~/.config. Moving the folder with
  # BH_TMP_DIR instead would also move the daemons' sockets, under one name for
  # every browser session (browser_harness/_ipc.py, _runtime_stem).
  services.hermes-agent.settings.gateway.media_delivery_allow_dirs = [
    "${server.hermes.home}/.config/browser-harness/tmp"
  ];

  home.activation.browserProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${profile}
    run chmod 0700 ${profile}
  '';
}
