# Test-only: install a known SSH host key so age can decrypt fixture .age files.
# Do NOT copy this pattern into real systems.
{ config, lib, ... }:
{
  system.activationScripts.installSSHHostKeys = {
    text = ''
      mkdir -p /etc/ssh
      install -m 0644 ${./keys/system1.pub} /etc/ssh/ssh_host_ed25519_key.pub
      install -m 0600 ${./keys/system1}     /etc/ssh/ssh_host_ed25519_key
    '';
    deps = [ "specialfs" ];
  };

  # Order: installSSHHostKeys must run before agenix decrypts. Extend agenix's
  # existing deps rather than replacing them. Under systemd-sysusers/userborn
  # agenix decrypts from a systemd unit, which runs after activation anyway.
  system.activationScripts.agenixInstall =
    lib.mkIf (!(config.systemd.sysusers.enable || config.services.userborn.enable))
      {
        deps = lib.mkAfter [ "installSSHHostKeys" ];
      };
}
