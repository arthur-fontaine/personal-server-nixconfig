# Sandboxed Pi sessions, when server.hermes.sandbox is on: the sandbox plugin
# (../plugins/sandbox: sandbox_run, sandbox_status, sandbox_result,
# sandbox_stop) and the sidecar it starts per session (pkgs.hermes-sandbox,
# ../sandbox). Listed in plugins.enabled by memory.nix, which holds that list.
# Everything a session keeps is under ~/.hermes/sandbox: the guest image, the
# builder's cache, one directory per session.
{ lib, pkgs, server, ... }:
let
  cfg = server.hermes.sandbox;
  plugin = pkgs.runCommand "hermes-plugin-sandbox" { } ''
    cp -R ${../plugins/sandbox} $out
  '';
in
lib.mkIf cfg.enable {
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
    };
  };
}
