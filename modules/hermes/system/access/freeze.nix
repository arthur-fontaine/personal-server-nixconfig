# Hermes writes or deletes only what it created in the last 24 hours. Its own
# account cannot write the administrator's files, and hermes-freeze hands every
# file it created to the administrator, behind a deny ACL, once it is old
# enough (freeze.py explains how).
{ config, pkgs, ... }:
let
  cfg = config.server.hermes;

  freezeConfig = pkgs.writeText "hermes-freeze.json" (builtins.toJSON {
    agent_user = cfg.user;
    admin_user = config.server.admin.user;
    freeze_after = cfg.access.freezeAfter;
    ledger = "/var/db/hermes-freeze/ledger.json";
    roots = [
      {
        path = cfg.home;
        exclude = map (d: "${cfg.home}/${d}") cfg.access.mutableDirs;
      }
      { path = "/Users/Shared"; }
      { path = "/private/tmp"; }
      { path = "/private/var/tmp"; }
    ];
  });
in
{
  launchd.daemons.hermes-freeze.serviceConfig = {
    ProgramArguments = [ "${pkgs.python3}/bin/python3" "-I" "${./freeze.py}" "${freezeConfig}" ];
    StartInterval = cfg.access.scanInterval;
    RunAtLoad = true;
    LowPriorityIO = true;
    Nice = 10;
    StandardOutPath = "/var/log/hermes-freeze.log";
    StandardErrorPath = "/var/log/hermes-freeze.log";
  };

  system.activationScripts.postActivation.text = ''
    mkdir -p /var/db/hermes-freeze
    chmod 700 /var/db/hermes-freeze
  '';
}
