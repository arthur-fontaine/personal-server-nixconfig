# The Hermes iOS app (apps/hermes-ios) on the owner's iPhones and iPads,
# built, signed and installed from this Mac (docs/app.md):
#   hermes_app/  hermes-app, the CLI and launchd job: xcodegen, xcodebuild
#                with Xcode's automatic signing, devicectl over the network
#   plugin/      the Hermes plugin "app_delivery": app_devices, app_install
#   tests/       both, against fake xcrun, xcodebuild and xcodegen (checks: app)
#
# Signing is Xcode's own, with the Apple Account signed in to Xcode on
# Hermes' account (scripts/bootstrap/apple.sh): a free personal team by
# default, whose profiles last 7 days, so the job re-signs and reinstalls
# before they expire. Rejected: AltServer and Sideloadly (GUI apps, no CLI),
# SideStore (re-signs on the device, through a VPN app and a pairing file,
# and would still need the builds from here), zsign/isideload (no Apple
# Account flow of their own, or Apple's private signing API through an
# anisette server): Xcode is installed anyway (modules/system/xcode.nix) and
# devicectl installs over the network since Xcode 15.
#
# Two modules, as ../coding-agent: `options` for nix-darwin (server.hermes.app.delivery,
# and the iOS platform Xcode needs), `agent` for Hermes' home-manager. The
# plugin is listed in plugins.enabled by ../agent/memory.nix.
let
  # home-manager's name for launchd.agents.hermes-app, which the session's
  # activation manages (../agent/session/launchd.nix).
  label = "org.nix-community.home.hermes-app";
in
{
  options = { config, lib, ... }:
    let
      inherit (lib) mkOption types;
      cfg = config.server.hermes.app.delivery;
      source = ../../../apps/hermes-ios;
    in
    {
      options.server.hermes.app.delivery = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Build the Hermes iOS app here and install it on the owner's devices
            (paired once by cable), re-signing it before its profile expires.
            Needs Xcode (server.xcode.enable) and an Apple Account signed in to
            Xcode on Hermes' account (bootstrap-macos.sh apple).
          '';
        };
        team = {
          id = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "A1B2C3D4E5";
            description = ''
              The signing team. Null: the one of the Apple Account signed in to
              Hermes' Xcode, its free personal team unless `paid`.
            '';
          };
          paid = mkOption {
            type = types.bool;
            default = false;
            description = ''
              The team is a paid Apple Developer Program membership: profiles
              last a year, and the app gets push notifications (HERMES_PAID_TEAM).
            '';
          };
        };
        bundleIdPrefix = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            The app's bundle ids start with it (…app, …app.widgets). Null:
            org.personal-server.hermes.<team id>, unique to the team, which a
            free team needs (another team may hold any other id).
          '';
        };
        source = mkOption {
          type = types.nullOr types.path;
          default = if builtins.pathExists source then builtins.path { path = source; name = "hermes-ios"; } else null;
          defaultText = lib.literalExpression "apps/hermes-ios of this repository";
          description = "The app's XcodeGen project.";
        };
        scheme = mkOption {
          type = types.str;
          default = "HermesApp";
        };
        refreshBefore = mkOption {
          type = types.ints.positive;
          default = 48;
          description = ''
            Hours before a device's profile expires when the job rebuilds and
            reinstalls the app there with a new one: a free profile lasts 7
            days, and the device may be away for a day or two.
          '';
        };
        checkInterval = mkOption {
          type = types.ints.positive;
          default = 6 * 3600;
          description = "Seconds between the job's runs, which do what is due (and retry what failed).";
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [{
          assertion = config.server.xcode.enable;
          message = "server.hermes.app.delivery needs Xcode: server.xcode.enable.";
        }];
        # Since Xcode 15, a build for an iOS device fails with "iOS N is not
        # installed" until the platform is downloaded (about 8 GB). After
        # xcode.nix's own step, which installs and selects Xcode.
        system.activationScripts.postActivation.text = lib.mkAfter ''
          (
            if xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer$'; then
              sdk=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)
              if [ -n "$sdk" ] && ! xcrun simctl list runtimes 2>/dev/null | grep -q "^iOS $sdk"; then
                echo "downloading the iOS $sdk platform for the Hermes app (about 8 GB)..." >&2
                xcodebuild -downloadPlatform iOS </dev/null \
                  || echo "warning: could not download the iOS platform; the app's build waits for it" >&2
              fi
            fi
          )
        '';
      };
    };

  agent = { config, lib, pkgs, server, ... }:
    let
      cfg = server.hermes.app.delivery;
      home = server.hermes.home;
      settings = pkgs.writeText "hermes-app.json" (builtins.toJSON {
        inherit home;
        source = if cfg.source == null then "" else toString cfg.source;
        inherit (cfg) scheme;
        team_id = cfg.team.id;
        paid = cfg.team.paid;
        bundle_id_prefix = cfg.bundleIdPrefix;
        refresh_before_hours = cfg.refreshBefore;
        state_dir = "${home}/.hermes/app";
        cache_dir = "${home}/Library/Caches/hermes-app";
        secrets_file = server.hermes.secretsFile;
        launchd_label = label;
        tools.xcodegen = lib.getExe pkgs.xcodegen;
      });
      hermes-app = pkgs.writeShellScriptBin "hermes-app" ''
        export HERMES_APP_CONFIG=${settings}
        # Apple's tools (xcrun, xcodebuild, security, defaults) are macOS' own.
        export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
        exec ${pkgs.python3}/bin/python3 -I ${./hermes_app/cli.py} "$@"
      '';
      plugin = pkgs.runCommand "hermes-plugin-app-delivery" { } ''
        cp -R ${./plugin} $out
      '';
    in
    lib.mkIf cfg.enable {
      home.packages = [ hermes-app ];
      services.hermes-agent = {
        extraPlugins = [ plugin ];
        hermesHomeFiles."app-delivery.json" = builtins.toJSON {
          command = lib.getExe hermes-app;
          state_dir = "${home}/.hermes/app";
        };
      };
      # In Hermes' GUI session, where its login keychain (the signing key,
      # Xcode's account) is unlocked; RunAtLoad catches up after a reboot.
      launchd.agents.hermes-app = {
        enable = true;
        config = {
          # The utility clamp of Hermes' own commands (../agent/tools.nix): a
          # build waits behind the gateway on a busy Mac.
          ProgramArguments = [ "/usr/sbin/taskpolicy" "-c" "utility" (lib.getExe hermes-app) "run" ];
          RunAtLoad = true;
          StartInterval = cfg.checkInterval;
          ProcessType = "Standard";
          StandardOutPath = "${home}/Library/Logs/hermes-app.log";
          StandardErrorPath = "${home}/Library/Logs/hermes-app.log";
        };
      };
    };
}
