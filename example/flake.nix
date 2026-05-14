{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    agenix-extras = {
      url = "path:..";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix-extras,
      home-manager,
    }:

    {
      nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit agenix-extras; };
        modules = [
          agenix-extras.nixosModules.default
          home-manager.nixosModules.home-manager
          ./configuration.nix
        ];
      };
    };
}
