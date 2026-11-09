# Hermes writes or deletes only what it created in the last 24 hours. Its own
# account cannot write the administrator's files, and hermes-freeze hands every
# file it created to the administrator, behind a deny ACL, once it is old
# enough (freeze.py explains how).
{ config, lib, pkgs, ... }:
let
  cfg = config.server.hermes;

  freezeConfig = pkgs.writeText "hermes-freeze.json" (builtins.toJSON {
    agent_user = cfg.user;
    admin_user = config.server.admin.user;
    freeze_after = cfg.access.freezeAfter;
    ledger = "/var/db/hermes-freeze/ledger.json";
    report = spaceReport;
    roots = [
      {
        path = cfg.home;
        exclude = map (d: "${cfg.home}/${d}") cfg.access.mutablePaths;
        # Only Hermes' files are in its home: one the administrator owns was frozen.
        leftovers = true;
      }
      { path = "/Users/Shared"; }
      { path = "/private/tmp"; }
      { path = "/private/var/tmp"; }
    ];
  });

  # Readable by Hermes and the owner; written by hermes-freeze (root).
  spaceReport = "/var/db/hermes-space/report.json";
  hermes-space = pkgs.writeShellScriptBin "hermes-space" ''
    HERMES_SPACE_REPORT=${spaceReport} HERMES_SPACE_HOME=${lib.escapeShellArg cfg.home} \
      exec ${pkgs.python3}/bin/python3 -I ${./space.py} "$@"
  '';
  weeklyConfig = pkgs.writeText "hermes-space-weekly.json" (builtins.toJSON {
    report = spaceReport;
    home = cfg.home;
    threshold = cfg.access.space.weeklyThreshold;
    secrets_file = cfg.secretsFile;
  });
in
lib.mkIf config.server.hermes.enable {
  environment.systemPackages = [ hermes-space ];

  # The owner's line when the frozen leftovers grow past the threshold:
  # Monday morning, at most once a week, never a deletion.
  launchd.daemons.hermes-space-weekly.serviceConfig = {
    ProgramArguments = [ "${pkgs.python3}/bin/python3" "-I" "${./space.py}" "weekly" "${weeklyConfig}" ];
    StartCalendarInterval = [ { Weekday = 1; Hour = 10; Minute = 0; } ];
    StandardOutPath = "/var/log/hermes-space.log";
    StandardErrorPath = "/var/log/hermes-space.log";
  };

  launchd.daemons.hermes-freeze.serviceConfig = {
    # Under the launcher, so Full Disk Access lets it into Desktop, Documents and Downloads.
    ProgramArguments = [ cfg.access.launcher "${pkgs.python3}/bin/python3" "-I" "${./freeze.py}" "${freezeConfig}" ];
    StartInterval = cfg.access.scanInterval;
    RunAtLoad = true;
    LowPriorityIO = true;
    Nice = 10;
    StandardOutPath = "/var/log/hermes-freeze.log";
    StandardErrorPath = "/var/log/hermes-freeze.log";
  };

  system.activationScripts.postActivation.text = ''
    mkdir -p /var/db/hermes-freeze /var/db/hermes-space
    chmod 700 /var/db/hermes-freeze
    chmod 755 /var/db/hermes-space
  '';
}
