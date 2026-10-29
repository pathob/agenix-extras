# Evaluation-only tests: the module's assertions and option constraints,
# checked without booting a VM. A mismatch fails evaluation, so
# `nix flake check --no-build` catches it too.
{
  pkgs,
  self,
}:

let
  inherit (pkgs) lib;

  eval =
    module:
    (self.inputs.nixpkgs.lib.nixosSystem {
      modules = [
        self.nixosModules.default
        {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.11";
          age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
          age.secrets.token.file = ./secrets/api-token.age;
        }
        module
      ];
    }).config;

  # Messages of this module's failed assertions.
  failed =
    config:
    lib.filter (m: lib.hasPrefix "age.templates" m || lib.hasPrefix "agenix-extras:" m) (
      map (a: a.message) (lib.filter (a: !a.assertion) config.assertions)
    );

  usesToken =
    { config, ... }:
    {
      age.templates.t.content = "token = ${config.age.placeholder.token}";
    };

  cases = {
    valid = {
      module =
        { config, ... }:
        {
          age.templates.inline.content = config.age.placeholder.token;
          age.templates.file.file = ../example/module.nix;
          age.secrets.token.restartUnits = [
            "foo.service"
            "foo@bar.service"
            "foo.socket"
          ];
        };
      expect = [ ];
    };

    neither-file-nor-content = {
      module.age.templates.t = { };
      expect = [ "age.templates.t: set exactly one of `file` and `content`." ];
    };

    both-file-and-content = {
      module.age.templates.t = {
        content = "x";
        file = ../example/module.nix;
      };
      expect = [ "age.templates.t: set exactly one of `file` and `content`." ];
    };

    relative-path = {
      module.age.templates.t = {
        content = "x";
        path = "relative/t";
      };
      expect = [
        "age.templates.t.path must be an absolute path without `.`, `..` or empty components; got: relative/t"
      ];
    };

    non-normalised-path = {
      module.age.templates.t = {
        content = "x";
        path = "/run/agenix-extras/./t";
      };
      expect = [
        "age.templates.t.path must be an absolute path without `.`, `..` or empty components; got: /run/agenix-extras/./t"
      ];
    };

    duplicate-paths = {
      module.age.templates = {
        a = {
          content = "x";
          path = "/run/x";
        };
        b = {
          content = "y";
          path = "/run/x";
        };
        # Not involved, so not mentioned.
        c = {
          content = "z";
          path = "/run/y";
        };
      };
      expect = [ "age.templates: a, b all render to /run/x." ];
    };

    secret-disabled = {
      module = {
        imports = [ usesToken ];
        age.secrets.token.enable = false;
      };
      expect = [
        "age.templates.t uses age.secrets.token, which is not decrypted because age.secrets.token.enable is false."
      ];
    };

    agenix-disabled = {
      module = {
        imports = [ usesToken ];
        age.enable = false;
      };
      expect = [
        "age.templates.t uses age.secrets.token, which is not decrypted because age.enable is false."
      ];
    };

    unit-without-suffix = {
      module.age.secrets.token.restartUnits = [ "nginx" ];
      expect = [
        "agenix-extras: `nginx` in restartUnits/reloadUnits is not a systemd unit name (expected e.g. `nginx.service`)."
      ];
    };
  };

  mismatches = lib.filter (x: x != null) (
    lib.mapAttrsToList (
      name: c:
      let
        got = failed (eval c.module);
      in
      if got == c.expect then
        null
      else
        "${name}:\n    expected: ${builtins.toJSON c.expect}\n    got:      ${builtins.toJSON got}"
    ) cases
  );

  # Users must not be able to set the placeholders themselves.
  placeholderIsReadOnly =
    !(builtins.tryEval (eval { age.placeholder.token = "x"; }).age.placeholder).success;

  modeOk =
    mode:
    (builtins.tryEval
      (eval {
        age.templates.t = {
          content = "x";
          inherit mode;
        };
      }).age.templates.t.mode
    ).success;

  # Option values that should hold, by description.
  values =
    let
      config = eval {
        users.users.svc = {
          isSystemUser = true;
          group = "svcgroup";
        };
        users.groups.svcgroup = { };
        age.templates = {
          owned = {
            content = "x";
            owner = "svc";
          };
          unowned.content = "x";
        };
      };
    in
    {
      "template group defaults to the owner's primary group" =
        config.age.templates.owned.group == "svcgroup";
      "template group defaults to 0 for the default owner" = config.age.templates.unowned.group == "0";
      "template mode accepts symbolic modes" = modeOk "u=r,g=r";
      "template mode accepts leading zeros" = modeOk "000440";
      "template mode accepts an operator before octal" = modeOk "=0440";
      "template mode rejects ls-style modes" = !(modeOk "rw-r-----");
    };

  # Regression: these used to fail evaluation ("attribute 'agenix' missing").
  evaluates = map (m: (eval m).system.build.toplevel.drvPath) [
    {
      imports = [ usesToken ];
      services.userborn.enable = true;
    }
    {
      age.secrets = lib.mkForce { };
      age.templates.static.content = "no secrets";
    }
  ];

  errors =
    mismatches
    ++ lib.optional (!placeholderIsReadOnly) "age.placeholder can be set by users"
    ++ lib.mapAttrsToList (name: _: "does not hold: ${name}") (lib.filterAttrs (_: ok: !ok) values);
in

assert lib.assertMsg (errors == [ ]) (
  "agenix-extras eval tests failed:\n  " + lib.concatStringsSep "\n  " errors
);
builtins.deepSeq evaluates (pkgs.writeText "agenix-extras-eval" "ok")
