# Tests that restartUnits fires when a secret's plaintext changes between
# activations, for a unit defined by NixOS, a unit that only a package
# provides, and template instances.
{
  pkgs,
  self,
}:

let
  sleep = "${pkgs.coreutils}/bin/sleep infinity";

  # A unit NixOS knows nothing about beyond `systemd.packages`.
  pkgdemo = pkgs.writeTextDir "etc/systemd/system/pkgdemo.service" ''
    [Service]
    ExecStart=${sleep}
  '';
in

pkgs.testers.runNixOSTest {
  name = "agenix-extras-restart-on-change";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ./install-ssh-host-key.nix
      ];

      # Set in the `dropped` specialisation, which removes every restartUnits
      # entry and the NixOS-defined `inst@c` instance.
      options.test.dropped = lib.mkEnableOption "the configuration without restartUnits";

      config = {
        age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

        age.secrets.api-token = {
          file = ./secrets/api-token.age;
          restartUnits = lib.mkIf (!config.test.dropped) [
            "demo.service"
            "pkgdemo.service"
            "inst@a.service"
            "inst@c.service"
            "inst@d.service"
          ];
        };

        systemd.services.demo = {
          description = "Long-running service that should be restarted on secret change";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = sleep;
            Restart = "no";
          };
        };

        systemd.packages = [ pkgdemo ];

        # Template. `a` only gets our drop-in, `b` isn't listed at all, and `c`
        # and `d` are instances NixOS itself defines.
        systemd.services."inst@".serviceConfig.ExecStart = sleep;
        systemd.services."inst@c" = lib.mkIf (!config.test.dropped) {
          overrideStrategy = "asDropin";
          wantedBy = [ "multi-user.target" ];
        };
        # Same as `c`, but declared as a raw unit.
        systemd.units."inst@d.service" = lib.mkIf (!config.test.dropped) {
          overrideStrategy = "asDropin";
          text = "[Unit]\nDescription=Raw instance\n";
          wantedBy = [ "multi-user.target" ];
        };

        # Same secret name, different ciphertext (decrypts to "tok-BBB"). This
        # is what triggers restartUnits.
        specialisation.bumped.configuration = {
          age.secrets.api-token.file = lib.mkForce ./secrets/api-token.v2.age;
        };

        specialisation.dropped.configuration = {
          test.dropped = true;
        };
      };
    };

  testScript = ''
    units = ["demo.service", "pkgdemo.service", "inst@a.service", "inst@b.service", "inst@c.service", "inst@d.service"]

    def pids(units):
      out = {}
      for u in units:
        pid = machine.succeed(f"systemctl show -p MainPID --value {u}").strip()
        assert pid not in ("", "0"), f"{u} is not running"
        out[u] = pid
      return out

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("demo.service")
    machine.wait_for_unit("inst@c.service")
    machine.wait_for_unit("inst@d.service")
    machine.succeed("systemctl start pkgdemo.service inst@a.service inst@b.service")

    # Sanity: baseline secret content.
    assert "tok-AAA" == machine.succeed("cat /run/agenix/api-token").strip()

    # The triggers must extend the real units, not replace them with stubs
    # (regression: units only provided by a package, and template instances,
    # got a generated unit file without ExecStart).
    for u in ["pkgdemo.service", "inst@a.service", "inst@c.service", "inst@d.service"]:
      unit = machine.succeed(f"systemctl cat {u}")
      assert "ExecStart=" in unit, unit
      assert "agenix-extras.conf" in unit, unit

    before = pids(units)
    base = machine.succeed("readlink -f /run/current-system").strip()

    # Switching to the specialisation changes the secret's `.age` store path,
    # which changes the X-Restart-Triggers in each listed unit's drop-in, which
    # makes switch-to-configuration restart them.
    machine.succeed(f"{base}/specialisation/bumped/bin/switch-to-configuration test")

    # New plaintext must be on disk.
    assert "tok-BBB" == machine.succeed("cat /run/agenix/api-token").strip()

    # Listed units have a fresh PID; the unlisted instance was left alone.
    after = pids(units)
    for u in ["demo.service", "pkgdemo.service", "inst@a.service", "inst@c.service", "inst@d.service"]:
      assert after[u] != before[u], f"{u} was not restarted: pid {before[u]} -> {after[u]}"
    assert after["inst@b.service"] == before["inst@b.service"], "inst@b.service was restarted"

    # Dropping units from restartUnits must not stop them, but instances
    # that NixOS stops defining must still be stopped as usual.
    machine.succeed(f"{base}/specialisation/dropped/bin/switch-to-configuration test")
    pids(["demo.service", "pkgdemo.service", "inst@a.service", "inst@b.service"])
    machine.fail("systemctl is-active inst@c.service")
    machine.fail("systemctl is-active inst@d.service")
  '';
}
