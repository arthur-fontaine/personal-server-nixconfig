# hosts/local.nix again, with a JSON patch merged into one host. Used by
# scripts/bootstrap-macos.sh and scripts/uninstall-macos.sh:
#
#   REPO="$PWD" HOST=My-Server PATCH='{"server":{"hermes":{"enable":false}}}' \
#     nix eval --impure --raw --file scripts/lib/set-host.nix
let
  repo = builtins.getEnv "REPO";
  host = builtins.getEnv "HOST";
  patch = builtins.fromJSON (builtins.getEnv "PATCH");
  lib = (builtins.getFlake "path:${repo}").inputs.nixpkgs.lib;
  localFile = "${repo}/hosts/local.nix";
  local = if builtins.pathExists localFile then import localFile else { };
  current = (import "${repo}/hosts").${host};
in
''
  # This Mac's host, written by scripts/bootstrap-macos.sh and
  # scripts/uninstall-macos.sh. Git-ignored.
''
+ lib.generators.toPretty { } (local // { ${host} = lib.recursiveUpdate current patch; })
+ "\n"
