# Sandboxed Pi sessions (agent/sandbox.nix, plugins/sandbox, ../sandbox): Hermes
# hands a coding task to Pi in a Gondolin microVM and reviews its branch.
{ lib, ... }:
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
        The hosts the guest may reach over HTTP(S), exact or "*.domain" for
        its subdomains; everything else gets 403. Nothing but HTTP leaves it.
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
}
