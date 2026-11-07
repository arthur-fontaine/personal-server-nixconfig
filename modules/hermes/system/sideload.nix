# Hermes and the sideload service (../../sideload, docs/sideload.md): the
# Hermes iOS app declared as one of its apps, and Hermes' access to it.
#
# - server.hermes.app.delivery.enable: the Hermes app (apps/hermes-ios) is a
#   sideload app named "hermes", built with the current pet (written by the
#   App topic to ~/.hermes/app/pet/) and Hermes' Telegram settings; it turns
#   the service on. Its devices are written to ~/.hermes/app/delivery.json,
#   and `hermes-app` (install, status, devices) stays the command app-backend
#   calls, now a thin shim over `sideload … hermes`.
# - server.hermes.sideload.enable (on with the service): the plugin
#   ../plugins/sideload gives Hermes its tools (sideload_devices,
#   sideload_apps, sideload_install, sideload_remove), through the CLI. The
#   service runs as Hermes' account by default, so Hermes calls it directly
#   and its state stays under ~/Library (a mutable path of the account).
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  hermes = config.server.hermes;
  cfg = hermes.app.delivery;
  home = hermes.home;
  source = ../../../apps/hermes-ios;
  sideload = config.server.sideload;
  hermesApp = pkgs.writeShellScriptBin "hermes-app" ''
    # The Hermes app's commands, as app-backend calls them (hermes-app-work/DECISIONS.md).
    cmd="''${1:-status}"; shift || true
    case "$cmd" in
      install) exec ${lib.getExe sideload.package} install hermes "$@" ;;
      status) exec ${lib.getExe sideload.package} status hermes ;;
      devices) exec ${lib.getExe sideload.package} devices ;;
      run) exec ${lib.getExe sideload.package} run ;;
      *) echo "usage: hermes-app install|status|devices|run" >&2; exit 2 ;;
    esac
  '';
in
{
  options.server.hermes.app.delivery = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install the Hermes iOS app on the owner's devices through the sideload
        service (server.sideload, turned on with it), re-signed before its
        profile expires.
      '';
    };
    bundleIdPrefix = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The app's bundle ids start with it (…app, …app.widgets). Null: org.personal-server.hermes.<team id>.";
    };
    source = mkOption {
      type = types.nullOr types.path;
      default = if builtins.pathExists source then builtins.path { path = source; name = "hermes-ios"; } else null;
      defaultText = lib.literalExpression "apps/hermes-ios of this repository";
      description = "The app's XcodeGen project.";
    };
    scheme = mkOption { type = types.str; default = "HermesApp"; };
  };
  options.server.hermes.sideload.enable = mkOption {
    type = types.bool;
    default = sideload.enable;
    defaultText = lib.literalExpression "config.server.sideload.enable";
    description = "Hermes' tools for the sideload service (list devices and apps, install, remove).";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      server.sideload.enable = true;
      server.sideload.apps.hermes = {
        name = "Hermes";
        source = if cfg.source == null then "" else cfg.source;
        inherit (cfg) scheme bundleIdPrefix;
        prefixName = "hermes";
        teamEnv = { team_id = "HERMES_TEAM_ID"; bundle_id_prefix = "HERMES_BUNDLE_ID_PREFIX"; paid = "HERMES_PAID_TEAM"; };
        # The app is a Telegram client of the owner's account (TDLib): its API id.
        secretEnv = { HERMES_TG_API_ID = "TELEGRAM_API_ID"; HERMES_TG_API_HASH = "TELEGRAM_API_HASH"; };
        envCommands.HERMES_BOT_USERNAME = ''
          . ${hermes.secretsFile} 2>/dev/null; [ -n "$TELEGRAM_BOT_TOKEN" ] \
            && /usr/bin/curl -fsS --max-time 15 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe" \
            | ${lib.getExe pkgs.jq} -r '.result.username // empty' '';
        inputs = [
          { from = "${home}/.hermes/app/pet/icon.png"; to = "HermesApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"; }
          { from = "${home}/.hermes/app/pet/pet.json"; to = "Pet/pet.json"; }
          { from = "${home}/.hermes/app/pet/spritesheet.webp"; to = "Pet/spritesheet.webp"; }
        ];
        versionFile = "${home}/.hermes/app/pet/pet.json";
        statusFile = "${home}/.hermes/app/delivery.json";
      };
      home-manager.users.${hermes.user}.home.packages = [ hermesApp ];
    })
    (lib.mkIf hermes.sideload.enable {
      assertions = [{
        assertion = sideload.enable && sideload.user == hermes.user;
        message = "server.hermes.sideload needs the sideload service on (server.sideload.enable), running as Hermes' account (server.sideload.user).";
      }];
      home-manager.users.${hermes.user}.services.hermes-agent = {
        extraPlugins = [ (pkgs.runCommand "hermes-plugin-sideload" { } "cp -R ${../plugins/sideload} $out") ];
        hermesHomeFiles."sideload/config.json" = builtins.toJSON {
          command = lib.getExe sideload.package;
          state_dir = "${config.users.users.${sideload.user}.home}/Library/Application Support/sideload";
          files_dir = "${home}/.hermes/cache/sideload";
        };
      };
    })
  ];
}
