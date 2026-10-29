# Tests the home-manager module in a real user session: templates rendered
# by agenix.service at login, and user units restarted or reloaded with the
# new contents when home-manager switches to a changed secret.
{
  pkgs,
  self,
  home-manager,
}:

pkgs.testers.runNixOSTest {
  name = "agenix-extras-home-manager";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];

      # Lingering, so alice's user manager (and with it agenix.service) runs
      # without a login.
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
      };

      # Test-only: alice's agenix identity is the key the fixtures are
      # encrypted to.
      system.activationScripts.aliceIdentity = {
        text = ''
          install -d -m 0700 -o alice -g users /home/alice/.ssh
          install -m 0600 -o alice -g users ${./keys/system1} /home/alice/.ssh/id_ed25519
        '';
        deps = [ "users" ];
      };

      home-manager.useGlobalPkgs = true;
      home-manager.users.alice =
        { config, ... }:
        {
          imports = [ self.homeManagerModules.default ];

          home.stateVersion = "25.11";

          age.identityPaths = [ "/home/alice/.ssh/id_ed25519" ];
          age.secrets.api-token = {
            file = ./secrets/api-token.age;
            restartUnits = [ "restarted.service" ];
          };

          age.templates."app.toml" = {
            content = ''
              token = "${config.age.placeholder.api-token}"
            '';
            reloadUnits = [ "consumer.service" ];
          };
          age.templates."other.conf".content = ''
            other = "${config.age.placeholder.api-token}"
          '';

          # Records what the template looked like when it started / reloaded.
          systemd.user.services.consumer = {
            Service = {
              ExecStart = "${pkgs.bash}/bin/bash -c 'cp $XDG_RUNTIME_DIR/agenix-extras/app.toml $XDG_RUNTIME_DIR/consumer-start; exec ${pkgs.coreutils}/bin/sleep infinity'";
              ExecReload = "${pkgs.bash}/bin/bash -c 'cp $XDG_RUNTIME_DIR/agenix-extras/app.toml $XDG_RUNTIME_DIR/consumer-reload'";
            };
            Install.WantedBy = [ "default.target" ];
          };

          systemd.user.services.restarted = {
            Service.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            Install.WantedBy = [ "default.target" ];
          };
        };

      # Same secret name, different ciphertext (decrypts to "tok-BBB").
      specialisation.bumped.configuration = {
        home-manager.users.alice.age.secrets.api-token.file = lib.mkForce ./secrets/api-token.v2.age;
      };

      # app.toml removed in the same switch in which decryption fails.
      specialisation.failing.configuration = {
        home-manager.users.alice.age = {
          identityPaths = lib.mkForce [ "/nonexistent" ];
          templates = lib.mkForce {
            "other.conf".content = "other = \"unchanged\"\n";
          };
        };
      };

      # The last secret and template removed, which disables agenix.
      specialisation.disabled.configuration = {
        home-manager.users.alice.age = {
          secrets = lib.mkForce { };
          templates = lib.mkForce { };
        };
      };
    };

  testScript = ''
    run = "/run/user/1000"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("home-manager-alice.service")
    machine.wait_for_unit("consumer.service", "alice")
    machine.wait_for_unit("restarted.service", "alice")

    # Rendered by agenix.service right after decrypting, private to alice.
    rendered = machine.succeed(f"cat {run}/agenix-extras/app.toml")
    assert 'token = "tok-AAA"' in rendered, rendered
    perms = machine.succeed(f"stat -c '%a %U' {run}/agenix-extras/app.toml").strip()
    assert perms == "400 alice", perms
    dir_perms = machine.succeed(f"stat -c '%a %U' {run}/agenix-extras").strip()
    assert dir_perms == "700 alice", dir_perms

    # The consumer only started once the template existed.
    started = machine.succeed(f"cat {run}/consumer-start")
    assert 'token = "tok-AAA"' in started, started

    def main_pid(unit):
      return machine.succeed(
        f"systemctl --user -M alice@ show -p MainPID --value {unit}"
      ).strip()

    pid_before = main_pid("restarted.service")
    base = machine.succeed("readlink -f /run/current-system").strip()

    # A changed secret: home-manager starts agenix.service again, which
    # re-renders, and the consumers are reloaded / restarted after it.
    machine.succeed(f"{base}/specialisation/bumped/bin/switch-to-configuration test")
    rendered = machine.succeed(f"cat {run}/agenix-extras/app.toml")
    assert 'token = "tok-BBB"' in rendered, rendered
    reloaded = machine.succeed(f"cat {run}/consumer-reload")
    assert 'token = "tok-BBB"' in reloaded, reloaded
    pid_after = main_pid("restarted.service")
    assert pid_after not in ("", "0", pid_before), f"restarted.service: {pid_before} -> {pid_after}"

    # A symlink where the rendered directory should be is never followed, as
    # stale files in it would be removed: nothing is rendered or removed.
    machine.succeed(
      "runuser -u alice -- mkdir -p /home/alice/keep",
      "runuser -u alice -- touch /home/alice/keep/precious",
      f"mv {run}/agenix-extras {run}/agenix-extras.saved",
      f"runuser -u alice -- ln -s /home/alice/keep {run}/agenix-extras",
    )
    machine.fail("systemctl --user -M alice@ restart agenix.service")
    machine.succeed("test -e /home/alice/keep/precious")
    machine.succeed(
      f"rm {run}/agenix-extras",
      f"mv {run}/agenix-extras.saved {run}/agenix-extras",
      "systemctl --user -M alice@ restart agenix.service",
    )

    # A template removed while decryption fails (so ExecStartPost doesn't run)
    # is removed anyway (ExecStopPost); the remaining one isn't rendered, so it
    # keeps its previous file.
    other = machine.succeed(f"cat {run}/agenix-extras/other.conf")
    machine.execute(f"{base}/specialisation/failing/bin/switch-to-configuration test")
    machine.succeed(f"test ! -e {run}/agenix-extras/app.toml")
    assert other == machine.succeed(f"cat {run}/agenix-extras/other.conf")
    machine.succeed(f"{base}/bin/switch-to-configuration test")
    machine.succeed(f"test -e {run}/agenix-extras/app.toml")

    # Removing the last secret and template disables agenix (and with it
    # agenix.service); the rendered file is removed anyway.
    machine.succeed(f"{base}/specialisation/disabled/bin/switch-to-configuration test")
    machine.succeed(f"test ! -e {run}/agenix-extras/app.toml")
  '';
}
