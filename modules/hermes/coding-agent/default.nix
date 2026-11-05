# The coding agent: Hermes hands a coding task to Pi in a Gondolin microVM and
# reviews its branch (docs/sandbox.md). Everything of it is in this folder:
#   hermes-plugin/  the Hermes plugin "sandbox" (sandbox_run…, the broker's actions)
#   sidecar/        hermes-sandbox, the Node host owning one VM (pkgs/hermes-sandbox.nix)
#   pi/             Pi as the image has it: its packages, settings.json, advisor.json, extensions/
#   tests/          the plugin's tests, against a fake sidecar (checks: coding-agent)
#
# Two modules, for two module systems: `options` is nix-darwin's
# server.hermes.sandbox (imported by ../options), `agent` Hermes' home-manager
# wiring (imported by ../agent). The plugin is listed in plugins.enabled by
# ../agent/memory.nix, which holds that list.
{
  options = { config, lib, ... }:
    let
      inherit (lib) mkOption types;
      cfg = config.server.hermes.sandbox;
      provider = model: builtins.head (lib.splitString "/" model);
    in
    {
      options.server.hermes.sandbox = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Give Hermes sandbox_run and its companions: Pi sessions in a microVM
            with no access to this Mac but a copy of one git repository, and the
            network to its model only. The provider's key (keyEnv) must be in
            the secrets file; the guest image is built at the first session.
          '';
        };
        model = mkOption {
          type = types.str;
          default = "opencode-go/deepseek-v4.1-flash";
          description = ''
            Pi's model, as Pi names it (provider/id), from Pi's catalog: the
            bootstrap lists them (scripts/lib/pi-models.mjs). The provider's key
            is keyEnv, Pi reads it from piKeyEnv, and it goes to keyHosts only.
          '';
        };
        thinking = mkOption {
          type = types.enum [ "off" "minimal" "low" "medium" "high" "xhigh" "max" ];
          # This model takes low, high or max: Pi would clamp medium to high anyway.
          default = "high";
          description = "Pi's thinking level, one the model supports (Pi clamps another to the nearest).";
        };
        # pi-advisor-flow in the guest: Pi (the executor) asks a second call
        # of a model for a review at its plan, its failures and its end, and
        # when it repeats a tool call. Through Pi's provider, so the same key
        # and hosts (keyHosts); the rest is ./pi/advisor.json.
        advisor = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Give Pi an advisor (pi-advisor-flow), active from the start of each session.";
          };
          model = mkOption {
            type = types.str;
            default = "opencode-go/deepseek-v4.1-flash";
            description = ''
              The advisor's model (provider/id). It may be Pi's own: the
              advisor reviews at a higher effort. On Pi's provider, the one the
              guest reaches with a key.
            '';
          };
          effort = mkOption {
            type = types.enum [ "minimal" "low" "medium" "high" "xhigh" "max" ];
            # deepseek-v4.1-flash takes low, high or max (pi-ai's opencode-go catalog).
            default = "max";
            description = "The advisor's thinking level.";
          };
          maxCalls = mkOption {
            type = types.ints.unsigned;
            default = 5;
            description = ''
              Advisor calls per session, Pi's own and the automatic gates'
              together; then Pi goes on alone.
            '';
          };
          contextMaxChars = mkOption {
            type = types.ints.positive;
            default = 15000;
            description = "Characters of the session's conversation an advisor call carries at most.";
          };
        };
        keyEnv = mkOption {
          type = types.str;
          default = "OPENCODE_GO_API_KEY";
          description = ''
            The variable of the secrets file holding the provider's key. The
            guest gets a placeholder; the host puts the key in the requests to
            keyHosts only.
          '';
        };
        piKeyEnv = mkOption {
          type = types.str;
          default = "OPENCODE_API_KEY";
          description = ''
            The variable Pi reads the provider's key from (pi-ai's
            env-api-keys): in the guest, it holds the placeholder.
          '';
        };
        keyHosts = mkOption {
          type = types.listOf types.str;
          default = [ "opencode.ai" ];
          description = ''
            The hosts of the provider's API (its models' baseUrl in Pi's
            catalog): the only ones the key is put in requests to.
          '';
        };
        allowedHosts = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "*.npmjs.org" ];
          description = ''
            Hosts the guest may reach over HTTP(S) from the start besides the
            provider's (keyHosts) and hermes.sandbox (Hermes' broker, answered
            on the host): exact, or "*.domain" for its subdomains. For any
            other, Pi asks Hermes for access and Hermes' approval system
            decides; a refusal is a 403. Nothing but HTTP leaves it.
          '';
        };
        approvalTimeout = mkOption {
          type = types.ints.positive;
          default = 300;
          description = ''
            Seconds the owner has to answer a sandbox's question (a host Pi asks
            Hermes for, when the auto-review does not clear it); no answer refuses.
          '';
        };
        memory = mkOption {
          type = types.str;
          default = "3G";
          description = "The VM's memory (QEMU syntax). One session runs at a time.";
        };
        cpus = mkOption {
          type = types.ints.positive;
          default = 2;
        };
        timeout = mkOption {
          type = types.ints.positive;
          default = 7200;
          description = "Seconds a session may run before it is stopped (what Pi committed stays).";
        };
      };
      # One provider's key reaches the guest: the advisor's requests go
      # through it too.
      config.assertions = lib.optional (cfg.enable && cfg.advisor.enable) {
        assertion = provider cfg.advisor.model == provider cfg.model;
        message = "server.hermes.sandbox.advisor.model (${cfg.advisor.model}) must be on Pi's provider (${provider cfg.model}).";
      };
    };

  # Everything a session keeps is under ~/.hermes/sandbox: the guest image,
  # the builder's cache, one directory per session.
  agent = { lib, pkgs, server, ... }:
    let
      cfg = server.hermes.sandbox;
      plugin = pkgs.runCommand "hermes-plugin-sandbox" { } ''
        cp -R ${./hermes-plugin} $out
      '';
    in
    lib.mkIf cfg.enable {
      # On Hermes' PATH for `hermes-sandbox smoke` and `build-image`.
      home.packages = [ pkgs.hermes-sandbox ];
      services.hermes-agent = {
        extraPlugins = [ plugin ];
        hermesHomeFiles."sandbox/config.json" = builtins.toJSON {
          command = lib.getExe pkgs.hermes-sandbox;
          state_dir = "${server.hermes.home}/.hermes/sandbox";
          inherit (cfg) model thinking memory cpus;
          advisor = { inherit (cfg.advisor) enable model effort maxCalls contextMaxChars; };
          timeout_seconds = cfg.timeout;
          # Read from Hermes' environment (the secrets file) by name; a
          # placeholder under Pi's name in the guest, the key on the way to
          # the provider's hosts only.
          key_env = cfg.keyEnv;
          pi_key_env = cfg.piKeyEnv;
          key_hosts = cfg.keyHosts;
          grants = lib.unique (cfg.keyHosts ++ cfg.allowedHosts);
          max_diff_chars = 30000;
          # Pi asks Hermes for access to other hosts: guard's review first when
          # it is on (../agent/guard.nix, its model and config), then the owner.
          auto_review = server.hermes.decision.approval.enable;
          approval_timeout = cfg.approvalTimeout;
          # Whose secret folders request_folder refuses: Hermes' own and the
          # administrator's, which Hermes reads (../system/access/read.nix).
          homes = [ server.hermes.home server.admin.home ];
        };
      };
    };
}
