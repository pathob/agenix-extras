{
  description = "agenix with sops-nix-style templates and unit reload-on-change";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Only for the home-manager module's tests; the module itself works with
    # whichever home-manager it is imported into.
    home-manager = {
      url = "github:nix-community/home-manager";
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

      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      checks = eachSystem (
        system:

        let
          pkgs = nixpkgs.legacyPackages.${system};
        in

        {
          formatting = pkgs.runCommand "agenix-extras-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            cd ${self}
            find . -name '*.nix' -exec nixfmt --check {} +
            touch $out
          '';
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux" || system == "aarch64-linux") {
          # Evaluates the example configuration (the README points people at
          # it) without building the whole system.
          example =
            let
              example = nixpkgs.lib.nixosSystem {
                modules = [
                  self.nixosModules.default
                  ./example/configuration.nix
                  { nixpkgs.hostPlatform = system; }
                ];
              };
            in
            pkgs.writeText "agenix-extras-example" (
              builtins.unsafeDiscardStringContext example.config.system.build.toplevel.drvPath
            );

          eval = import ./tests/eval.nix { inherit pkgs self; };
          eval-home = import ./tests/eval-home.nix { inherit pkgs self home-manager; };
          home-manager = import ./tests/home-manager.nix { inherit pkgs self home-manager; };
          templates = import ./tests/templates.nix { inherit pkgs self; };
          restart-on-change = import ./tests/restart-on-change.nix { inherit pkgs self; };
          sysusers = import ./tests/sysusers.nix { inherit pkgs self; };
        }
      );
    };
}
