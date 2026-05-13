# Test-only: install a known SSH host key so age can decrypt fixture .age files.
# Do NOT copy this pattern into real systems.
{ lib, ... }:
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
  # existing deps rather than replacing them.
  system.activationScripts.agenixInstall.deps = lib.mkAfter [ "installSSHHostKeys" ];
}
