# The Hermes account's home-manager configuration: the agent itself, written
# from scratch with the upstream module
# (https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/nix/homeManagerModules.nix).
# No `hermes setup`: config.yaml is generated, and Hermes runs in managed mode,
# refusing edits that would drift from this repository.
{ server, ... }:
let
  cfg = server.hermes;
in
{
  imports = [
    ./model.nix
    ./memory.nix
    ./whatsapp.nix
    ./mcp.nix
  ];

  home.username = cfg.user;
  home.homeDirectory = cfg.home;
  home.stateVersion = "25.05";

  programs.hermes-agent.enable = true;

  services.hermes-agent = {
    enable = true;
    # The gateway is a launchd agent of the account's GUI session.
    gateway.enable = true;
    hermesHome = "${cfg.home}/.hermes";
    workingDirectory = "${cfg.home}/workspace";
    environmentFiles = [ cfg.secretsFile ];

    settings = {
      # Approvals arrive as WhatsApp messages; the guardian model decides the
      # obvious ones.
      approvals.mode = "smart";
      # Nix pins and updates Hermes (flake.lock), not Hermes itself.
      updates = {
        check = false;
        refresh_cua_driver = false;
      };
      telemetry.shared_metrics = {
        enabled = false;
        send = false;
      };
    };
  };
}
