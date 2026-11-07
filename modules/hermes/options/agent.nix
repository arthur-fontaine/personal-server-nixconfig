{ config, lib, ... }:
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
        only: the model providers' keys (OPENCODE_ZEN_API_KEY…),
        TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS, the integrations' keys.
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
          logged in by the bootstrap), "opencode-zen", any Hermes provider,
          or one of server.hermes.providers.
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
      example = [{ provider = "opencode-zen"; model = "deepseek-v4.1-flash"; } { provider = "openai-codex"; model = "gpt-6-luna"; }];
      description = ''
        Tried in order when the main model fails (a limit reached, an outage,
        an expired login), for that turn only: the next one tries the main
        model again. scripts/bootstrap-macos.sh asks for the chain.
      '';
    };
    backgroundModel = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          provider = mkOption { type = types.str; };
          model = mkOption { type = types.str; };
        };
      });
      default = if config.server.hermes.fallbacks == [ ] then null else lib.head config.server.hermes.fallbacks;
      defaultText = lib.literalExpression "the first of fallbacks, or null";
      description = ''
        The model of the work nobody reads: unii's summaries (unless
        memory.compactionModel names another) and Hermes' review after a turn,
        which writes skills. By default the first fallback, so a subscription
        chat model's quota goes to the chat; null: the main model.
      '';
    };
    providers = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          label = mkOption {
            type = types.str;
            default = name;
            description = "Its name in Hermes' model picker.";
          };
          url = mkOption {
            type = types.str;
            description = "Its OpenAI-compatible base URL, the one /models and /chat/completions hang from.";
          };
          keyEnv = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "The variable of the secrets file holding its API key; null when it takes none.";
          };
        };
      }));
      default = { };
      example = { mistral = { url = "https://api.mistral.ai/v1"; keyEnv = "MISTRAL_API_KEY"; }; };
      description = ''
        OpenAI-compatible APIs Hermes does not know, by name: that name is
        then a provider for the model and the fallbacks. The bootstrap adds
        them ("Another OpenAI-compatible API").
      '';
    };
    localFallback = mkOption {
      type = types.bool;
      default = true;
      description = "After the fallbacks, the local model (uzu): slow and small, but always there.";
    };

    # The main chat answers and dispatches (../plugins/front_desk): a turn
    # there holds every message the user sends behind it.
    frontDesk = {
      seconds = mkOption {
        type = types.ints.positive;
        # A step costs 3 to 6 s on a fresh session and up to ~30 s on a long
        # one (docs/hermes.md, "Speed"): two minutes is a handful of steps,
        # enough to answer, and the most a message should wait.
        default = 120;
        description = ''
          Seconds a turn of the main chat may run (the time spent waiting on
          the user's answer not counted) before its tool calls are blocked but
          delegate_task and the ones that answer or recall.
        '';
      };
      toolCalls = mkOption {
        type = types.ints.positive;
        # Several commands in one call and independent calls in one message
        # are the prompt's rule, so eight calls are a lookup, not a task.
        default = 8;
        description = "Tool calls a turn of the main chat may make before the same block.";
      };
      foregroundSeconds = mkOption {
        type = types.ints.positive;
        # A foreground command blocks even a steered message until it exits
        # (agent/interrupt_control.py: steer() never yields it).
        default = 60;
        description = ''
          A foreground command of the main chat with a longer timeout (or a
          build, an install, a test run, a longer sleep) runs in the
          background instead, and notifies when it exits.
        '';
      };
    };
  };
}
