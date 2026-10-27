{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.server.uzu = {
    enable = mkOption {
      type = types.bool;
      default = true;
    };
    model = mkOption {
      type = types.str;
      default = "alibaba:qwen3.5:4b:mirai:mirai-m:4";
      description = "The model `mirai server` serves. `mirai list-models` lists the others.";
    };
    port = mkOption {
      type = types.port;
      default = 8000;
    };
  };
}
