# hosts/local.nix again, with `server.hermes.enable` set for one host. Used by
# scripts/uninstall-macos.sh:
#
#   REPO="$PWD" HOST=My-Server ENABLE=false \
#     nix eval --impure --raw --file scripts/lib/hermes-enabled.nix
let
  repo = builtins.getEnv "REPO";
  host = builtins.getEnv "HOST";
  enable = builtins.getEnv "ENABLE" == "true";
  lib = (builtins.getFlake "path:${repo}").inputs.nixpkgs.lib;
  localFile = "${repo}/hosts/local.nix";
  local = if builtins.pathExists localFile then import localFile else { };
  current = (import "${repo}/hosts").${host};
in
''
  # This Mac's host, written by scripts/bootstrap-macos.sh and
  # scripts/uninstall-macos.sh. Git-ignored.
''
+ lib.generators.toPretty { } (local // { ${host} = lib.recursiveUpdate current { server.hermes.enable = enable; }; })
+ "\n"
