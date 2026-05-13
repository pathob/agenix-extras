# Tests that restartUnits fires when a secret's plaintext changes between activations.
{
  pkgs,
  self
}:

pkgs.testers.runNixOSTest {
  name = "agenix-extras-restart-on-change";

  nodes.machine =
    {
      config,
      ...
    }:

    {
      imports = [
        self.nixosModules.default
        ./install-ssh-host-key.nix
      ];

      age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      age.secrets.api-token = {
        file = ./secrets/api-token.age;
        restartUnits = [ "demo.service" ];
      };

      systemd.services.demo = {
        description = "Long-running service that should be restarted on secret change";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          Restart = "no";
        };
      };

      # Specialisation switches the same secret name to a different ciphertext
      # (decrypts to "tok-BBB"). This is what triggers restartUnits.
      specialisation.bumped.configuration = {
        age.secrets.api-token.file = pkgs.lib.mkForce ./secrets/api-token.v2.age;
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("demo.service")

    # Sanity: baseline secret content.
    assert "tok-AAA" == machine.succeed("cat /run/agenix/api-token").strip()

    pid_before = machine.succeed("systemctl show -p MainPID --value demo.service").strip()
    assert pid_before != "0" and pid_before != "", f"demo.service has no PID: {pid_before!r}"

    # Switching to the specialisation changes the secret's `.age` store path,
    # which alters the unit's eval-time restartTriggers, which makes
    # switch-to-configuration restart demo.service automatically.
    machine.succeed(
      "/run/current-system/specialisation/bumped/bin/switch-to-configuration test"
    )

    # New plaintext must be on disk.
    assert "tok-BBB" == machine.succeed("cat /run/agenix/api-token").strip()

    # demo.service should have a fresh PID.
    pid_after = machine.succeed("systemctl show -p MainPID --value demo.service").strip()
    assert pid_after != pid_before, (
      f"demo.service was not restarted: pid {pid_before} -> {pid_after}"
    )
  '';
}
