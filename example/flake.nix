{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix-extras = {
      url = "path:..";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      agenix-extras,
    }:

    {
      nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          agenix-extras.nixosModules.default
          home-manager.nixosModules.home-manager
          { home-manager.sharedModules = [ agenix-extras.homeManagerModules.default ]; }
          ./configuration.nix
        ];
      };
    };
}
