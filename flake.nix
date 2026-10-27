{
  description = "Declarative macOS personal server: a Hermes Agent and local models with uzu";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Both keep their own nixpkgs: their builds (uv2nix venv, Metal toolchain)
    # are tested against the revision their lock files pin.
    hermes-agent.url = "github:NousResearch/hermes-agent";
    uzu.url = "github:trymirai/uzu";
  };

  outputs = inputs@{ nixpkgs, nix-darwin, home-manager, ... }:
    let
      hosts = import ./hosts;

      mkDarwinConfiguration = hostName: hostConfig@{
        system,
        username,
        homeDirectory ? "/Users/${username}",
        nixconfigDir ? "${homeDirectory}/personal-server-nixconfig",
        ...
      }:
        let
          # `server` goes through the module system (below), not as an argument.
          specialArgs = removeAttrs hostConfig [ "server" ] // { inherit inputs hostName homeDirectory nixconfigDir; };
        in
        nix-darwin.lib.darwinSystem {
          inherit system specialArgs;
          modules = [
            ./modules/system
            ./modules/hermes
            ./modules/uzu
            home-manager.darwinModules.home-manager
            # A host's `server = { ... };` sets the options under server.*.
            { server = hostConfig.server or { }; }
            {
              users.users.${username}.home = homeDirectory;
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "hm-backup";
              home-manager.extraSpecialArgs = specialArgs;
              home-manager.users.${username} = import ./modules/home;
            }
          ];
        };
      overlay = import ./pkgs { inherit inputs; };
      pkgsFor = system: import nixpkgs { inherit system; overlays = [ overlay ]; };
    in
    {
      darwinConfigurations = nixpkgs.lib.mapAttrs mkDarwinConfiguration hosts;

      overlays.default = overlay;

      # The packages this repository adds, to build and try them alone.
      packages.aarch64-darwin = builtins.intersectAttrs (overlay { } { }) (pkgsFor "aarch64-darwin");

      checks.aarch64-darwin = import ./checks { inherit inputs; pkgs = pkgsFor "aarch64-darwin"; };

      # Two real Hermes turns on a scripted model, outside the build sandbox
      # (checks/hermes-turns/run.sh): `nix run .#hermes-turns`.
      apps.aarch64-darwin.hermes-turns =
        let
          pkgs = pkgsFor "aarch64-darwin";
          hermes = inputs.hermes-agent.packages.aarch64-darwin.default;
          run = pkgs.writeShellScript "hermes-turns" ''
            exec ${pkgs.bash}/bin/bash ${./checks/hermes-turns}/run.sh \
              ${hermes}/bin/hermes ${hermes.hermesVenv}/bin/python3 ${./modules/hermes/plugins/unii} "$@"
          '';
        in
        {
          type = "app";
          program = "${run}";
          meta.description = "Run two real Hermes turns through the unii memory against a scripted model";
        };
    };
}
