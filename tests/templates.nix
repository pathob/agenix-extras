# Boots the example module and asserts the rendered template contains the
# substituted secrets. The example module is the test fixture - keeping them
# in sync ensures the README's example actually works.
{
  pkgs,
  self,
}:

pkgs.testers.runNixOSTest {
  name = "agenix-extras-templates";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ../example/module.nix
        ./install-ssh-host-key.nix
      ];

      age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      users.users.reader = {
        isSystemUser = true;
        group = "reader";
      };
      users.groups.reader = { };

      # A `file` template owned by a non-root user. The file has to be generated
      # to contain the placeholders; `builtins.toFile` does that at evaluation
      # time, whereas `pkgs.writeText` would need import from derivation.
      age.templates."reader.conf" = {
        file = builtins.toFile "reader.conf.tpl" ''
          token = "${config.age.placeholder.api-token}"
        '';
        owner = "reader";
        group = "reader";
      };

      # A template outside the default directory, with a custom mode.
      age.templates."custom.conf" = {
        content = ''
          password = "${config.age.placeholder.db-password}"
        '';
        path = "/var/lib/agenix-extras-test/custom.conf";
        mode = "0440";
      };

      # One template that can't be rendered (unknown owner) next to one that
      # can, plus an /etc entry to prove the activation snippets that run
      # after ours still ran.
      specialisation.broken.configuration = {
        age.templates."app.toml".owner = lib.mkForce "nosuchuser";
        age.templates."other.conf".content = ''
          password = "${config.age.placeholder.db-password}"
        '';
        environment.etc."agenix-extras-marker".text = "activated";
      };

      # Turns the rendered file `app.toml` into a directory and back.
      specialisation.nested.configuration = {
        age.templates = lib.mkForce {
          "app.toml/inner".content = ''
            token = "${config.age.placeholder.api-token}"
          '';
        };
      };

      # Reaches the default directory through the /var/run -> /run symlink.
      specialisation.aliased.configuration = {
        age.templates."alias.conf" = {
          content = "token = \"${config.age.placeholder.api-token}\"\n";
          path = "/var/run/agenix-extras/alias.conf";
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Secrets are decrypted to /run/agenix.
    assert "tok-AAA" == machine.succeed("cat /run/agenix/api-token").strip()
    assert "pw-AAA"  == machine.succeed("cat /run/agenix/db-password").strip()

    # Template was rendered with placeholders substituted.
    rendered = machine.succeed("cat /run/agenix-extras/app.toml")
    assert 'token = "tok-AAA"' in rendered, rendered
    assert 'password = "pw-AAA"' in rendered, rendered

    # Placeholder strings must not leak into the rendered file.
    machine.fail("grep -q AGENIX:.*:PLACEHOLDER /run/agenix-extras/app.toml")

    # Default mode is 0400, owned by root.
    perms = machine.succeed("stat -c '%a %U %G' /run/agenix-extras/app.toml").strip()
    assert perms == "400 root root", perms

    # A `file` template, readable by its non-root owner through the 0751
    # directory, but by nobody else.
    reader = machine.succeed("runuser -u reader -- cat /run/agenix-extras/reader.conf")
    assert 'token = "tok-AAA"' in reader, reader
    machine.fail("runuser -u nobody -- cat /run/agenix-extras/reader.conf")

    # A template at a custom path, with a custom mode.
    custom = machine.succeed("cat /var/lib/agenix-extras-test/custom.conf")
    assert 'password = "pw-AAA"' in custom, custom
    perms = machine.succeed("stat -c '%a %U %G' /var/lib/agenix-extras-test/custom.conf").strip()
    assert perms == "440 root root", perms

    # Like agenix's own secrets, rendered plaintext lives on a ramfs so it is
    # never swapped to disk.
    fstype = machine.succeed("stat -f -c %T /run/agenix-extras").strip()
    assert fstype == "ramfs", fstype

    # The directory must be traversable by non-root so services running as a
    # non-root user can open() files inside it (regression: was 0700).
    dir_perms = machine.succeed("stat -c '%a %U %G' /run/agenix-extras").strip()
    assert dir_perms == "751 root root", dir_perms

    # Mode must survive re-activation.
    machine.succeed("/run/current-system/activate")
    dir_perms = machine.succeed("stat -c '%a %U %G' /run/agenix-extras").strip()
    assert dir_perms == "751 root root", dir_perms

    # A template that fails to render must fail the switch, but must not stop
    # the other templates or the rest of activation (regression: `set -e` in
    # our snippet aborted every snippet after it, including `etc`).
    base = machine.succeed("readlink -f /run/current-system").strip()
    status, out = machine.execute(
      f"{base}/specialisation/broken/bin/switch-to-configuration test 2>&1"
    )
    assert "activated" == machine.succeed("cat /etc/agenix-extras-marker").strip()
    assert status != 0, out
    assert "failed to render app.toml" in out, out
    other = machine.succeed("cat /run/agenix-extras/other.conf")
    assert 'password = "pw-AAA"' in other, other

    # The template that failed keeps its previous content rather than
    # disappearing.
    assert rendered == machine.succeed("cat /run/agenix-extras/app.toml")
    perms = machine.succeed("stat -c '%a %U %G' /run/agenix-extras/app.toml").strip()
    assert perms == "400 root root", perms

    # Switching back removes the rendered file of the template that no longer
    # exists, and leaves no temporary files behind.
    status, out = machine.execute(f"{base}/bin/switch-to-configuration test 2>&1")
    assert status == 0, out
    files = machine.succeed("ls -A /run/agenix-extras").split()
    assert files == ["app.toml", "reader.conf"], files

    # A rendered path may become a directory and vice versa (regression: the
    # stale file blocked `mkdir`, and the stale directory made `mv` move the
    # new file into it, where pruning then deleted it).
    status, out = machine.execute(
      f"{base}/specialisation/nested/bin/switch-to-configuration test 2>&1"
    )
    assert status == 0, out
    inner = machine.succeed("cat /run/agenix-extras/app.toml/inner")
    assert 'token = "tok-AAA"' in inner, inner

    status, out = machine.execute(f"{base}/bin/switch-to-configuration test 2>&1")
    assert status == 0, out
    assert rendered == machine.succeed("cat /run/agenix-extras/app.toml")

    # A path that reaches the default directory through a symlink counts as
    # being in it: it is rendered there, and not pruned as stale on the next
    # activation.
    machine.succeed("test $(readlink -f /var/run) = /run")
    aliased = f"{base}/specialisation/aliased/bin/switch-to-configuration test 2>&1"
    status, out = machine.execute(aliased)
    assert status == 0, out
    alias = machine.succeed("cat /run/agenix-extras/alias.conf")
    assert 'token = "tok-AAA"' in alias, alias
    status, out = machine.execute(aliased)
    assert status == 0, out
    assert "removing stale" not in out, out

    # If the ramfs can't be mounted (here: a file is in the way), templates at
    # other paths are still rendered, and nothing is written to the default
    # directory on plain /run, not even through a symlink.
    machine.succeed(
      "umount /run/agenix-extras",
      "rm -rf /run/agenix-extras && touch /run/agenix-extras",
      "rm /var/lib/agenix-extras-test/custom.conf",
    )
    status, out = machine.execute(f"{base}/bin/switch-to-configuration test 2>&1")
    custom = machine.succeed("cat /var/lib/agenix-extras-test/custom.conf")
    assert 'password = "pw-AAA"' in custom, custom
    assert status != 0, out
    assert "failed to mount ramfs" in out, out
    assert "not rendering app.toml" in out, out
    machine.succeed("test -f /run/agenix-extras && ! test -s /run/agenix-extras")
    status, out = machine.execute(aliased)
    assert status != 0, out
    assert "not rendering alias.conf" in out, out
    machine.succeed("test -f /run/agenix-extras && ! test -s /run/agenix-extras")

    # Once the obstacle is gone, everything is back.
    machine.succeed("rm /run/agenix-extras")
    status, out = machine.execute(f"{base}/bin/switch-to-configuration test 2>&1")
    assert status == 0, out
    assert rendered == machine.succeed("cat /run/agenix-extras/app.toml")
  '';
}
