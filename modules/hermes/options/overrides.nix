# Hermes' local config overlay: the copy `sudo server-rebuild` checked and
# placed in this checkout (hosts/hermes-overrides.json, git-ignored), from
# Hermes' own ~/.hermes/local/overrides.json. ../system/access/overrides has
# the checker and what may be in it; ../agent/overrides.nix applies it.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.server.hermes.localOverrides;
in
{
  options.server.hermes.localOverrides = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Apply the overlay Hermes keeps in ~/.hermes/local/overrides.json: MCP
        servers, skills, enabled plugins' settings and models, changed without
        a push. Only what its checker allows; `server-rebuild --no-overrides`
        applies once without it.
      '';
    };
    file = mkOption {
      type = types.nullOr types.path;
      # A path literal reads the checkout at evaluation (server-rebuild uses a
      # path: flake, which sees git-ignored files, as with hosts/local.nix).
      default = if builtins.pathExists ../../../hosts/hermes-overrides.json then ../../../hosts/hermes-overrides.json else null;
      defaultText = lib.literalExpression "hosts/hermes-overrides.json when it exists";
      description = "The applied overlay, as the checker normalized it.";
    };
    secretsFile = mkOption {
      type = types.str;
      default = "/etc/hermes/local-secrets.env";
      description = ''
        The keys the overlay's MCP servers name, copied by server-rebuild
        from Hermes' ~/.hermes/local/secrets.env: only those, never one the
        main secrets file sets, never a TELEGRAM_/HERMES_ variable or the like.
        Read by Hermes after the main file.
      '';
    };
    overlay = mkOption {
      type = types.attrsOf types.anything;
      default = if cfg.enable && cfg.file != null then builtins.fromJSON (builtins.readFile cfg.file) else { };
      defaultText = lib.literalExpression "the file's content, or { }";
      description = "The overlay in effect (tests set it directly).";
    };
  };
}
