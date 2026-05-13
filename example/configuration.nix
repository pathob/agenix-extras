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

  systemd.services.demo-api = {
    description = "Demo API consuming an agenix-extras template";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = "${pkgs.coreutils}/bin/cat ${config.age.templates."app.toml".path}";
  };
}
