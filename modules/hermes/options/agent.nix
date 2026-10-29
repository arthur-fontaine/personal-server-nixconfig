{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.hermes = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run Hermes. false stops it and everything it runs (gateway, uzu,
        fsearch, the freeze daemon, its sudo rights, the auto-login) and leaves
        its account and memory alone, so turning it back on restores it as it
        was. docs/uninstall.md has the details and the full removal.
      '';
    };
    user = mkOption {
      type = types.str;
      default = "hermes";
      description = "The dedicated macOS account Hermes runs as.";
    };
    uid = mkOption {
      type = types.int;
      default = 550;
    };
    gid = mkOption {
      type = types.int;
      default = 550;
    };
    home = mkOption {
      type = types.str;
      default = "/Users/hermes";
    };
    secretsFile = mkOption {
      type = types.str;
      default = "/etc/hermes/secrets.env";
      description = ''
        A dotenv file, outside the Nix store and readable by the Hermes user
        only: OPENCODE_ZEN_API_KEY, RUNPOD_API_KEY, TELEGRAM_BOT_TOKEN,
        TELEGRAM_ALLOWED_USERS.
        See MANUAL_SETUP.md.
      '';
    };

    browserPort = mkOption {
      type = types.port;
      default = 9222;
      description = "The DevTools port of Hermes' always-open browser, on loopback.";
    };
    disabledSkills = mkOption {
      type = types.listOf types.str;
      default = [
        # No account or key set up for these.
        "himalaya"
        "email-inbox-triage"
        "google-workspace"
        "notion"
        "airtable"
        "box"
        "teams-meeting-pipeline"
        "xurl"
        # Not installed, and each needs its own account.
        "claude-code"
        "codex"
        "opencode"
      ];
      description = ''
        Bundled Hermes skills it should not offer, because what they drive is
        not set up on this server. Remove a name once you set that up.
      '';
    };

    model = {
      provider = mkOption {
        type = types.str;
        default = "opencode-zen";
        description = ''
          The main model's provider: "openai-codex" (a ChatGPT subscription,
          logged in by the bootstrap), "opencode-zen", or any Hermes provider.
        '';
      };
      name = mkOption {
        type = types.str;
        # Paid (pay-as-you-go on opencode.ai): OpenCode's free models answer
        # only its own app, and refuse API clients with HTTP 429.
        default = "deepseek-v4.1-flash";
      };
    };
    fallbacks = mkOption {
      type = types.listOf (types.submodule {
        options = {
          provider = mkOption { type = types.str; };
          model = mkOption { type = types.str; };
        };
      });
      default = [ ];
      example = [{ provider = "opencode-zen"; model = "deepseek-v4.1-flash"; }];
      description = ''
        Tried in order when the main model fails (a limit reached, an outage,
        an expired login), for that turn only: the next one tries the main
        model again. scripts/bootstrap-macos.sh asks for the chain.
      '';
    };
    localFallback = mkOption {
      type = types.bool;
      default = true;
      description = "After the fallbacks, the local model (uzu): slow and small, but always there.";
    };
  };
}
