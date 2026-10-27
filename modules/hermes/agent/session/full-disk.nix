# The gateway starts under tcc-launcher (modules/hermes/system/access/full-disk.nix),
# so the Full Disk Access granted to it once reaches Hermes and every command
# it runs, whatever Hermes version is installed. (home-manager wraps the
# arguments in `wait4path /nix/store && exec …`, so the launcher is still the
# process launchd started.)
{ config, lib, server, ... }:
{
  launchd.agents.hermes-agent.config.ProgramArguments = lib.mkForce [
    server.hermes.access.launcher
    "${config.programs.hermes-agent.package}/bin/hermes"
    "gateway"
  ];
}
