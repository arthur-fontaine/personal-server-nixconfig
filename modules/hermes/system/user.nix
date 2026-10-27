# Hermes runs as its own macOS account. That account is the hard boundary of
# the access rules: it owns nothing of the administrator's, so it can read
# their files (access/read.nix) but never write them.
#
# Computer use needs a GUI session, so this is the account macOS logs in
# automatically at boot (MANUAL_SETUP.md), and Hermes' services are launchd
# agents of that session (../agent).
{ config, pkgs, ... }:
let
  cfg = config.server.hermes;
in
{
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
}
