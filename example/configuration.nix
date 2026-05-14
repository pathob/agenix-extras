{
  config,
  pkgs,
  agenix-extras,
  ...
}:

let
  user = "demo";
  homeDir = "/home/${user}";
in

{
  imports = [
    (import ./module.nix {
      apiToken = "${agenix-extras}/tests/secrets/api-token.age";
      dbPassword = "${agenix-extras}/tests/secrets/db-password.age";
    })
  ];

  system.stateVersion = "25.11";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  boot.loader.grub.device = "nodev";

  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # When the secrets backing app.toml change, reload (or restart) demo-api.
  age.templates."app.toml".reloadUnits = [ "demo-api.service" ];

  systemd.services.demo-api = {
    description = "Demo API consuming an agenix-extras template";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.coreutils}/bin/cat ${config.age.templates."app.toml".path}";
  };

  users.users.${user} = {
    isNormalUser = true;
    home = homeDir;
  };

  # Home-manager submodule for `${user}` — same shared `module.nix`, but
  # restartUnits points at a user-level unit instead of a system one.
  home-manager = {
    useGlobalPkgs = true;
    extraSpecialArgs = { inherit agenix-extras; };

    users.${user} = {
      imports = [
        agenix-extras.homeManagerModules.default
        ./home.nix
      ];

      home = {
        username = user;
        homeDirectory = homeDir;
        stateVersion = "25.11";
      };
    };
  };
}
