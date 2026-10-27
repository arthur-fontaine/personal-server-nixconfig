{ config, lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.uzu = {
    enable = mkOption {
      type = types.bool;
      # It runs in the Hermes account's session, which is gone with Hermes.
      default = config.server.hermes.enable;
      defaultText = lib.literalExpression "config.server.hermes.enable";
    };
    user = mkOption {
      type = types.str;
      default = config.server.hermes.user;
      description = ''
        The account whose GUI session runs the server. It needs a logged-in
        session for the Metal GPU and the login keychain uzu stores its state in.
      '';
    };
    model = mkOption {
      type = types.str;
      # Qwen 3.5 9B, 4-bit (about 5 GB): the largest that leaves the M1 Pro room to work.
      default = "alibaba:qwen3.5:9b:mirai:mirai-m:4";
      description = "The model `mirai server` serves. `mirai list-models` lists the others.";
    };
    port = mkOption {
      type = types.port;
      default = 8000;
    };
  };
}
