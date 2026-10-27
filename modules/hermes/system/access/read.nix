# Hermes reads anything. An inherited ACL opens the administrator's home to
# the Hermes account; `sudo hermes-read` reads any other file as root.
# (Desktop, Documents and Downloads also need Full Disk Access: MANUAL_SETUP.md.)
{ config, lib, pkgs, ... }:
let
  agent = config.server.hermes.user;
  home = config.server.admin.home;
  readAce = "user:${agent} allow read,execute,readattr,readextattr,readsecurity,file_inherit,directory_inherit";

  hermes-read = pkgs.writeShellScriptBin "hermes-read" ''
    set -eu
    cmd="''${1:-}"
    shift || true
    case "$cmd" in
      cat) exec /bin/cat -- "$@" ;;
      ls) exec /bin/ls -la -- "$@" ;;
      stat) exec /usr/bin/stat -- "$@" ;;
      *) echo "usage: sudo hermes-read <cat|ls|stat> <path>..." >&2; exit 2 ;;
    esac
  '';
in
{
  environment.systemPackages = [ hermes-read ];

  security.sudo.extraConfig = ''
    ${agent} ALL=(root) NOPASSWD: /run/current-system/sw/bin/hermes-read *
  '';

  system.activationScripts.postActivation.text = lib.mkAfter ''
    home=${lib.escapeShellArg home}
    if ! /bin/ls -led "$home" | grep -q "user:${agent} allow"; then
      echo "granting ${agent} read access to $home..." >&2
      /bin/chmod +a ${lib.escapeShellArg readAce} "$home" \
        || echo "warning: could not grant ${agent} read access to $home" >&2
    fi
    # New files inherit the grant; what is already there is walked once.
    marker=/var/db/hermes-read-acl
    if [ ! -e "$marker" ]; then
      echo "granting ${agent} read access to everything under $home (once)..." >&2
      /usr/bin/find "$home" -mindepth 1 -xdev -print0 2>/dev/null \
        | /usr/bin/xargs -0 /bin/chmod -h +a ${lib.escapeShellArg readAce} 2>/dev/null || true
      touch "$marker"
    fi
  '';
}
