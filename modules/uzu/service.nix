# `mirai server` (https://github.com/trymirai/uzu, crates/legacy/cli): one model
# on the GPU behind an OpenAI-compatible endpoint on localhost, from its pinned
# files (pkgs/uzu-models.nix). It answers whatever model name a request gives.
{ config, lib, pkgs, ... }:
let
  cfg = config.server.uzu;
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.mirai ];

    home-manager.users.${cfg.user} = { lib, ... }: {
      # Pinned, the model is a store path (old ones go with nix.gc); what
      # mirai downloaded itself before, ~5 GB a model, is no longer read.
      home.activation.uzuDownloads = lib.mkIf (cfg.modelFiles != null)
        (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run rm -rf "$HOME/.cache/mirai/models"
        '');

      launchd.agents.uzu = {
        enable = true;
        config = {
          ProgramArguments = [
            "${pkgs.mirai}/bin/mirai"
            "server"
            "--model"
            (if cfg.modelFiles != null then "${cfg.modelFiles}" else cfg.model)
            "--host"
            "127.0.0.1"
            "--port"
            (toString cfg.port)
          ];
          RunAtLoad = true;
          KeepAlive = true;
          ProcessType = "Background";
          StandardOutPath = "${config.users.users.${cfg.user}.home}/Library/Logs/uzu.log";
          StandardErrorPath = "${config.users.users.${cfg.user}.home}/Library/Logs/uzu.log";
        };
      };
    };
  };
}
