# The user's Instagram, through instagram.com in Hermes' browser (no API exists
# for a personal account): a skill (skills/instagram), and a browser that
# stays logged in. The bootstrap opens it for the user's first login; later
# logins come from 1Password (onepassword.nix).
{ lib, pkgs, server, ... }:
{
  services.hermes-agent.hermesHomeFiles."skills/social-media/instagram/SKILL.md" = ./skills/instagram/SKILL.md;

  services.hermes-agent.settings.browser = {
    # Its pinned Chromium, rather than one it downloads at first use.
    executable_path = "${pkgs.hermes-chromium}/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";
    # One profile for every session (in ~/.hermes, which never freezes), so
    # logins and cookies persist.
    user_data_dir = "browser-profile";
    # A window on Hermes' screen: sites treat headless browsers as bots.
    headed = true;
    # What Hermes gives its own Chromium, lost once a path is set: no keychain
    # dialog that nobody would answer. Cookies then use a fixed key, so the
    # profile itself is the secret: its folder is Hermes' only (below).
    chromium_args = [ "--use-mock-keychain" "--password-store=basic" ];
  };

  home.activation.browserProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${server.hermes.home}/.hermes/browser-profile
    run chmod 0700 ${server.hermes.home}/.hermes/browser-profile
  '';
}
