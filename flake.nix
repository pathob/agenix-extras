{
  description = "agenix with sops-nix-style templates and unit reload-on-change";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      home-manager,
      systems,
    }:

    let
      eachSystem = nixpkgs.lib.genAttrs (import systems);
    in

    {
      nixosModules.agenix-extras = {
        imports = [
          agenix.nixosModules.default
          ./modules/agenix-extras.nix
        ];
      };

      nixosModules.default = self.nixosModules.agenix-extras;

      homeManagerModules.agenix-extras = {
        imports = [
          agenix.homeManagerModules.default
          ./modules/agenix-extras-home.nix
        ];
      };

      homeManagerModules.default = self.homeManagerModules.agenix-extras;

      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      checks = eachSystem (
        system:

        let
          pkgs = nixpkgs.legacyPackages.${system};
        in

        nixpkgs.lib.optionalAttrs (system == "x86_64-linux" || system == "aarch64-linux") {
          templates = import ./tests/templates.nix { inherit pkgs self; };
          restart-on-change = import ./tests/restart-on-change.nix { inherit pkgs self; };
          templates-home = import ./tests/templates-home.nix { inherit pkgs self home-manager; };
        }
      );
    };
}
