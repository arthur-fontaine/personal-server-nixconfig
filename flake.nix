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
          specialArgs = hostConfig // { inherit inputs hostName homeDirectory nixconfigDir; };
        in
        nix-darwin.lib.darwinSystem {
          inherit system specialArgs;
          modules = [
            ./modules/darwin
            home-manager.darwinModules.home-manager
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
    in
    {
      darwinConfigurations = nixpkgs.lib.mapAttrs mkDarwinConfiguration hosts;
    };
}
