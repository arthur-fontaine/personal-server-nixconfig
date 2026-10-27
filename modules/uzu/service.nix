# `mirai server` (https://github.com/trymirai/uzu, crates/legacy/cli): one model
# on the GPU behind an OpenAI-compatible endpoint on localhost. It downloads the
# model on its first start.
{ config, lib, pkgs, ... }:
let
  cfg = config.server.uzu;
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.mirai ];

    home-manager.users.${cfg.user}.launchd.agents.uzu = {
      enable = true;
      config = {
        ProgramArguments = [
          "${pkgs.mirai}/bin/mirai"
          "server"
          "--model"
          cfg.model
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
}
