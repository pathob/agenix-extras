{ config, pkgs, ... }:
{
  imports = [ ./module.nix ];

  system.stateVersion = "25.11";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  boot.loader.grub.device = "nodev";

  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Reloaded (or restarted) when the template changes.
  age.templates."app.toml".reloadUnits = [ "demo-api.service" ];

  systemd.services.demo-api = {
    description = "Demo API consuming an agenix-extras template";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.coreutils}/bin/cat ${config.age.templates."app.toml".path}";
  };

  # A user with the same template through home-manager (see home.nix).
  users.users.demo.isNormalUser = true;
  home-manager.useGlobalPkgs = true;
  home-manager.users.demo = import ./home.nix;
}
