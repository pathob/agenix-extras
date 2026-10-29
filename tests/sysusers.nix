# Tests template rendering when users are managed by userborn. agenix then
# decrypts from systemd units instead of activation scripts (the same code
# path as systemd-sysusers), so templates are rendered by agenix-extras.service.
{
  pkgs,
  self,
}:

pkgs.testers.runNixOSTest {
  name = "agenix-extras-sysusers";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ./install-ssh-host-key.nix
      ];

      services.userborn.enable = true;

      age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      age.secrets.api-token.file = ./secrets/api-token.age;

      users.users.demo = {
        isSystemUser = true;
        group = "demo";
      };
      users.groups.demo = { };

      # Owned by a user that only exists once userborn has run.
      age.templates."app.toml" = {
        owner = "demo";
        group = "demo";
        content = ''
          token = "${config.age.placeholder.api-token}"
        '';
        reloadUnits = [ "consumer.service" ];
      };

      # Records what the template looked like when it started / reloaded.
      systemd.services.consumer = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.bash}/bin/bash -c 'cp /run/agenix-extras/app.toml /run/consumer-start; exec ${pkgs.coreutils}/bin/sleep infinity'";
          ExecReload = "${pkgs.coreutils}/bin/cp /run/agenix-extras/app.toml /run/consumer-reload";
        };
      };

      # Same secret name, different ciphertext (decrypts to "tok-BBB").
      specialisation.bumped.configuration = {
        age.secrets.api-token.file = lib.mkForce ./secrets/api-token.v2.age;
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl is-active agenix-extras.service")

    rendered = machine.succeed("cat /run/agenix-extras/app.toml")
    assert 'token = "tok-AAA"' in rendered, rendered
    perms = machine.succeed("stat -c '%a %U %G' /run/agenix-extras/app.toml").strip()
    assert perms == "400 demo demo", perms
    fstype = machine.succeed("stat -f -c %T /run/agenix-extras").strip()
    assert fstype == "ramfs", fstype

    # Normal services must not start before rendering has finished.
    after = machine.succeed("systemctl show -p After --value sysinit.target").split()
    assert "agenix-extras.service" in after, after
    started = machine.succeed("cat /run/consumer-start")
    assert 'token = "tok-AAA"' in started, started

    # A changed secret re-renders the template on switch, before consumers
    # are reloaded.
    machine.succeed(
      "/run/current-system/specialisation/bumped/bin/switch-to-configuration test"
    )
    assert "tok-BBB" == machine.succeed("cat /run/agenix/api-token").strip()
    rendered = machine.succeed("cat /run/agenix-extras/app.toml")
    assert 'token = "tok-BBB"' in rendered, rendered
    reloaded = machine.succeed("cat /run/consumer-reload")
    assert 'token = "tok-BBB"' in reloaded, reloaded
  '';
}
