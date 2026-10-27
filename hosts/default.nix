let
  sharedHosts = import ./shared.nix;
  localHosts = if builtins.pathExists ./local.nix then import ./local.nix else { };
in
sharedHosts // localHosts
