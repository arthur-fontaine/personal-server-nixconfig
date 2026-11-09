# sideload: iOS apps installed on the owner's iPhones and iPads from this Mac
# and kept signed (docs/sideload.md). A service of its own, not Hermes':
#   sideload/  the CLI and launchd job: Xcode projects built with Xcode's
#              automatic signing, .ipa files re-signed with the team,
#              devicectl over the network, re-signing before profiles expire
#   tests/     against fake xcrun, xcodebuild, xcodegen, codesign, ditto
#
# It runs as `server.sideload.user` in its GUI session, where that account's
# login keychain (Xcode's Apple Account, the signing key) is unlocked: by
# default Hermes' account, the one with a GUI session on this server, but
# nothing here depends on Hermes. Hermes gets access through its own plugin
# (../hermes/plugins/sideload, ../hermes/agent/sideload.nix), which calls the
# CLI; the Hermes app is one declared app (../hermes/system/sideload.nix).
#
# Signing is Xcode's own: a free personal team by default, whose profiles last
# 7 days. Rejected: AltServer and Sideloadly (GUI apps, no CLI), SideStore
# (re-signs on the device through a VPN app and a pairing file), zsign and
# isideload (no Apple Account flow of their own, or Apple's private signing
# API through an anisette server): Xcode is installed anyway
# (../system/xcode.nix) and devicectl installs over the network since Xcode 15.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.server.sideload;
  home = config.users.users.${cfg.user}.home;
  # home-manager's name for launchd.agents.sideload.
  label = "org.nix-community.home.sideload";

  app = types.submodule ({ name, ... }: {
    options = {
      name = mkOption { type = types.str; default = name; description = "Shown in lists."; };
      source = mkOption {
        type = types.either types.path types.str;
        description = "An Xcode project's directory (project.yml, .xcodeproj or .xcworkspace), or a git URL.";
      };
      ref = mkOption { type = types.nullOr types.str; default = null; description = "A git URL's branch or tag."; };
      scheme = mkOption { type = types.nullOr types.str; default = null; description = "Null: the project's name."; };
      bundleIdPrefix = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The app's bundle ids start with it. Null: org.personal-server.<prefixName>.<team id>, unique to the team, as a free team needs.";
      };
      prefixName = mkOption { type = types.str; default = "sideload.${name}"; };
      teamEnv = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { team_id = "HERMES_TEAM_ID"; bundle_id_prefix = "HERMES_BUNDLE_ID_PREFIX"; paid = "HERMES_PAID_TEAM"; };
        description = "Environment variables the project reads its team, bundle-id prefix and paid flag from; empty: DEVELOPMENT_TEAM and automatic signing are set on the command line.";
      };
      env = mkOption { type = types.attrsOf types.str; default = { }; description = "More build environment."; };
      secretEnv = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Build environment variable → key of the secrets file (environment, never arguments: ps shows arguments).";
      };
      envCommands = mkOption { type = types.attrsOf types.str; default = { }; description = "Build environment variable → a shell command printing its value."; };
      inputs = mkOption {
        type = types.listOf (types.submodule {
          options.from = mkOption { type = types.str; description = "A file outside the source (absent: skipped)."; };
          options.to = mkOption { type = types.str; description = "Where it goes in the copied source."; };
        });
        default = [ ];
        description = "Files copied into the source before each build (an icon a user chose).";
      };
      versionFile = mkOption { type = types.nullOr types.str; default = null; description = "A JSON file whose `version` is recorded with each install."; };
      statusFile = mkOption { type = types.nullOr types.str; default = null; description = "Where this app's devices are written as JSON after each change, for other readers."; };
    };
  });
in
{
  options.server.sideload = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install iOS apps (Xcode projects, .ipa files) on the owner's devices
        from this Mac and keep them signed. Needs Xcode (server.xcode.enable),
        an Apple Account signed in to `user`'s Xcode, and each device paired
        once by cable (the bootstrap's sideload steps).
      '';
    };
    user = mkOption {
      type = types.str;
      default = config.server.hermes.user;
      defaultText = lib.literalExpression "config.server.hermes.user";
      description = "The account it runs as, in its GUI session (its keychain signs).";
    };
    team = {
      id = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The signing team. Null: the one of the Apple Account in `user`'s Xcode, its free personal team unless `paid`.";
      };
      paid = mkOption {
        type = types.bool;
        default = false;
        description = "A paid Apple Developer Program team: profiles last a year, no 3-apps-per-device or 10-App-IDs-a-week limit.";
      };
    };
    apps = mkOption {
      type = types.attrsOf app;
      default = { };
      description = "Apps declared here (others are added at runtime: `sideload add`).";
    };
    refreshBefore = mkOption {
      type = types.ints.positive;
      default = 48;
      description = "Hours before a profile expires when the job rebuilds or re-signs and reinstalls (a free profile lasts 7 days; a device may be away a day or two).";
    };
    checkInterval = mkOption {
      type = types.ints.positive;
      default = 6 * 3600;
      description = "Seconds between the job's runs, which do what is due and retry what failed.";
    };
    secretsFile = mkOption {
      type = types.str;
      default = config.server.hermes.secretsFile;
      defaultText = lib.literalExpression "config.server.hermes.secretsFile";
      description = "Where `secretEnv` reads its keys.";
    };
    package = mkOption { type = types.package; readOnly = true; description = "The `sideload` command."; };
  };

  config = lib.mkMerge [
    {
      server.sideload.package =
        let
          settings = pkgs.writeText "sideload.json" (builtins.toJSON {
            inherit home;
            state_dir = "${home}/Library/Application Support/sideload";
            cache_dir = "${home}/Library/Caches/sideload";
            team = cfg.team;
            refresh_before_hours = cfg.refreshBefore;
            secrets_file = cfg.secretsFile;
            launchd_label = label;
            # A failed re-sign is told to the owner with Hermes' bot; without
            # Hermes, the service stays silent (sideload status, the log).
            notify = if config.server.hermes.enable then { secrets_file = config.server.hermes.secretsFile; } else null;
            tools.xcodegen = lib.getExe pkgs.xcodegen;
            apps = lib.mapAttrs (_: a: {
              inherit (a) name ref scheme env inputs;
              source = toString a.source;
              bundle_id_prefix = a.bundleIdPrefix;
              prefix_name = a.prefixName;
              team_env = a.teamEnv;
              secret_env = a.secretEnv;
              env_commands = a.envCommands;
              version_file = a.versionFile;
              status_file = a.statusFile;
            }) cfg.apps;
          });
        in
        pkgs.writeShellScriptBin "sideload" ''
          export SIDELOAD_CONFIG=${settings}
          # Apple's tools (xcrun, xcodebuild, codesign, ditto, security, defaults) are macOS' own.
          export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
          exec ${pkgs.python3}/bin/python3 -I ${./sideload/cli.py} "$@"
        '';
    }
    (lib.mkIf cfg.enable {
      assertions = [{
        assertion = config.server.xcode.enable;
        message = "server.sideload needs Xcode: server.xcode.enable.";
      }];
      environment.systemPackages = [ cfg.package ];
      # Since Xcode 15 a build for an iOS device fails with "iOS N is not
      # installed" until the platform is downloaded (about 8 GB). After
      # xcode.nix's own step, which installs and selects Xcode.
      system.activationScripts.postActivation.text = lib.mkAfter ''
        (
          if xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer$'; then
            sdk=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)
            if [ -n "$sdk" ] && ! xcrun simctl list runtimes 2>/dev/null | grep -q "^iOS $sdk"; then
              echo "downloading the iOS $sdk platform for sideload (about 8 GB)..." >&2
              xcodebuild -downloadPlatform iOS </dev/null \
                || echo "warning: could not download the iOS platform; builds wait for it" >&2
            fi
          fi
        )
      '';
      home-manager.users.${cfg.user} = {
        # In the account's GUI session, where its login keychain is unlocked;
        # RunAtLoad catches up after a reboot.
        launchd.agents.sideload = {
          enable = true;
          config = {
            # A build waits behind interactive work on a busy Mac.
            ProgramArguments = [ "/usr/sbin/taskpolicy" "-c" "utility" (lib.getExe cfg.package) "run" ];
            RunAtLoad = true;
            StartInterval = cfg.checkInterval;
            ProcessType = "Standard";
            StandardOutPath = "${home}/Library/Logs/sideload.log";
            StandardErrorPath = "${home}/Library/Logs/sideload.log";
          };
        };
      };
    })
  ];
}
