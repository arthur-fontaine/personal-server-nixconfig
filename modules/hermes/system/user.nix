# Hermes runs as its own macOS account. That account is the hard boundary of
# the access rules: it owns nothing of the administrator's, so it can read
# their files (access/read.nix) but never write them.
#
# Computer use needs a GUI session, so this is the account macOS logs in
# automatically at boot (MANUAL_SETUP.md), and Hermes' services are launchd
# agents of that session (../agent).
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.server.hermes;
in
# Disabled, the account is no longer managed (not in knownUsers), so
# nix-darwin leaves it and its data as they are.
lib.mkIf cfg.enable {
  users.knownUsers = [ cfg.user ];
  users.knownGroups = [ cfg.user ];

  users.groups.${cfg.user} = {
    gid = cfg.gid;
    description = "Hermes Agent";
  };

  users.users.${cfg.user} = {
    uid = cfg.uid;
    gid = cfg.gid;
    home = cfg.home;
    createHome = true;
    shell = pkgs.zsh;
    description = "Hermes";
  };

  # macOS logs this account in at boot. The password that goes with it,
  # /etc/kcpassword, is a secret: scripts/bootstrap-macos.sh writes it.
  system.defaults.loginwindow.autoLoginUser = cfg.user;

  # loginwindow sets autoLoginUserScreenLocked when this account's screen
  # locks (someone logging in at the Mac's screen switches it out), and locks
  # the session again right after the next boot's automatic login: a lock
  # screen nobody can answer, since nobody knows the password. Cleared as soon
  # as it is written, and at boot.
  launchd.daemons.hermes-unlock-at-boot.serviceConfig = {
    ProgramArguments = [
      "/bin/sh" "-c"
      "/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked >/dev/null 2>&1 && /usr/bin/defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked; true"
    ];
    WatchPaths = [ "/Library/Preferences/com.apple.loginwindow.plist" ];
    RunAtLoad = true;
  };

  home-manager.users.${cfg.user} = {
    imports = [
      inputs.hermes-agent.homeManagerModules.default
      ../agent
    ];
    _module.args.server = config.server;
  };
}
