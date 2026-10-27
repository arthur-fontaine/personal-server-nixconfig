# Hermes changes the system only through this repository: it pushes a commit,
# then `sudo server-rebuild` pulls it into the administrator's checkout and
# applies it. Whoever can push to the repository can therefore change the
# whole machine, Hermes included.
{ config, lib, pkgs, hostName, ... }:
let
  server-rebuild = pkgs.writeShellScriptBin "server-rebuild" ''
    set -euo pipefail
    dir=${lib.escapeShellArg config.server.nixconfig.dir}
    /usr/bin/sudo -u ${config.server.admin.user} -H /run/current-system/sw/bin/git -C "$dir" pull --ff-only
    exec /run/current-system/sw/bin/darwin-rebuild switch --flake "path:$dir#${hostName}"
  '';
in
{
  environment.systemPackages = [ server-rebuild ];

  security.sudo.extraConfig = ''
    ${config.server.hermes.user} ALL=(root) NOPASSWD: /run/current-system/sw/bin/server-rebuild
  '';
}
