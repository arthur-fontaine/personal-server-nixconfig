# The coding agent: Hermes hands a coding task to Pi in a Gondolin microVM and
# reviews its branch (docs/sandbox.md). Everything of it is in this folder:
#   hermes-plugin/  the Hermes plugin "sandbox" (sandbox_run…, the broker's actions)
#   sidecar/        hermes-sandbox, the Node host owning one VM (pkgs/hermes-sandbox.nix)
#   pi/             Pi as the image has it: its packages, settings.json, extensions/
#   tests/          the plugin's tests, against a fake sidecar (checks: coding-agent)
#
# Two modules, for two module systems: `options` is nix-darwin's
# server.hermes.sandbox (imported by ../options), `agent` Hermes' home-manager
# wiring (imported by ../agent). The plugin is listed in plugins.enabled by
# ../agent/memory.nix, which holds that list.
{
  options = { lib, ... }:
    let
      inherit (lib) mkOption types;
    in
    {
      options.server.hermes.sandbox = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Give Hermes sandbox_run and its companions: Pi sessions in a microVM
            with no access to this Mac but a copy of one git repository, and the
            network to its model only. The OpenCode Go key (keyEnv) must be in
            the secrets file; the guest image is built at the first session.
          '';
        };
        model = mkOption {
          type = types.str;
          default = "opencode-go/deepseek-v4.1-flash";
          description = "Pi's model, as Pi names it (provider/id).";
        };
        thinking = mkOption {
          type = types.enum [ "off" "minimal" "low" "medium" "high" "xhigh" "max" ];
          # This model has no medium: Pi would clamp it to high anyway.
          default = "high";
          description = "Pi's thinking level.";
        };
        keyEnv = mkOption {
          type = types.str;
          default = "OPENCODE_GO_API_KEY";
          description = ''
            The variable of the secrets file holding the OpenCode Go key. The
            guest gets a placeholder; the host puts the key in the requests to
            opencode.ai only.
          '';
        };
        allowedHosts = mkOption {
          type = types.listOf types.str;
          default = [ "opencode.ai" ];
          example = [ "opencode.ai" "*.npmjs.org" ];
          description = ''
            The hosts the guest may reach over HTTP(S) from the start, exact or
            "*.domain" for its subdomains, besides hermes.sandbox (Hermes' broker,
            answered on the host). For any other, Pi asks Hermes for access and
            Hermes' approval system decides; a refusal is a 403. Nothing but
            HTTP leaves it.
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
          timeout_seconds = cfg.timeout;
          # Read from Hermes' environment (the secrets file) by name.
          key_env = cfg.keyEnv;
          grants = cfg.allowedHosts;
          max_diff_chars = 30000;
          # Pi asks Hermes for access to other hosts: guard's review first when
          # it is on (../agent/guard.nix, its model and config), then the owner.
          auto_review = server.hermes.decision.approval.enable;
          approval_timeout = cfg.approvalTimeout;
        };
      };
    };
}
