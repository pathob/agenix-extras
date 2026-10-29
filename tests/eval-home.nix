# Evaluation-only tests for the home-manager module: assertions, warnings
# and the generated units, checked without booting a VM. A mismatch fails
# evaluation, so `nix flake check --no-build` catches it too.
{
  pkgs,
  self,
  home-manager,
}:

let
  inherit (pkgs) lib;

  # Evaluated like home-manager's own `homeManagerConfiguration`, but without
  # its check that throws on failed assertions, so the tests can read them.
  hmLib = import "${home-manager}/modules/lib/stdlib-extended.nix" lib;
  hmModules = import "${home-manager}/modules/modules.nix" {
    inherit pkgs;
    lib = hmLib;
  };
  eval =
    module:
    (hmLib.evalModules {
      class = "homeManager";
      specialArgs.modulesPath = "${home-manager}/modules";
      modules = hmModules ++ [
        self.homeManagerModules.default
        {
          home.username = "alice";
          home.homeDirectory = "/home/alice";
          home.stateVersion = "25.11";
          age.identityPaths = [ "/home/alice/.ssh/id_ed25519" ];
          age.secrets.token.file = ./secrets/api-token.age;
        }
        module
      ];
    }).config;

  # Messages of this module's failed assertions.
  failed =
    config:
    lib.filter (m: lib.hasPrefix "age.templates" m || lib.hasPrefix "agenix-extras" m) (
      map (a: a.message) (lib.filter (a: !a.assertion) config.assertions)
    );
  ownWarnings = config: lib.filter (lib.hasPrefix "agenix-extras") config.warnings;

  usesToken =
    { config, ... }:
    {
      age.templates.t.content = "token = ${config.age.placeholder.token}";
    };

  # A user unit for the triggers to apply to.
  consumer = {
    systemd.user.services.consumer.Service.ExecStart = "${pkgs.coreutils}/bin/true";
  };

  cases = {
    valid = {
      module = {
        imports = [
          usesToken
          consumer
        ];
        age.templates.t.reloadUnits = [ "consumer.service" ];
        age.templates.elsewhere = {
          content = "x";
          path = "\${HOME}/elsewhere";
        };
        # agenix's paths use this unbraced form too.
        age.templates.unbraced = {
          content = "x";
          path = "$HOME/unbraced";
        };
      };
      assertions = [ ];
      warnings = [ ];
    };

    relative-path = {
      module.age.templates.t = {
        content = "x";
        path = "relative/t";
      };
      assertions = [
        "age.templates.t.path must be an absolute path without `.`, `..` or empty components; got: relative/t"
      ];
      warnings = [ ];
    };

    systemd-disabled = {
      module = {
        imports = [ usesToken ];
        systemd.user.enable = false;
      };
      assertions = [
        "agenix-extras: templates and restartUnits/reloadUnits need home-manager's systemd integration (systemd.user.enable), which agenix.service and the units come from."
      ];
      warnings = [ ];
    };

    agenix-disabled = {
      module = {
        age.secrets = lib.mkForce { };
        age.templates.static.content = "no secrets";
      };
      assertions = [
        "age.templates: templates are rendered by agenix's agenix.service, which only exists while age.enable is true (by default, when at least one secret is enabled)."
      ];
      warnings = [ ];
    };

    unmanaged-unit = {
      module.age.secrets.token.restartUnits = [ "elsewhere.service" ];
      assertions = [ ];
      warnings = [
        "agenix-extras: `elsewhere.service` in restartUnits/reloadUnits isn't defined in this home-manager configuration, and home-manager only restarts or reloads units it manages."
      ];
    };

    instance = {
      module.age.secrets.token.restartUnits = [ "foo@bar.service" ];
      assertions = [ ];
      warnings = [
        "agenix-extras: `foo@bar.service` in restartUnits/reloadUnits is a template instance, but home-manager applies changes per template. List `foo@.service` instead, which restarts or reloads all of its instances."
      ];
    };

    dotted-instance = {
      module.age.secrets.token.restartUnits = [ "foo@alice.smith.service" ];
      assertions = [ ];
      warnings = [
        "agenix-extras: `foo@alice.smith.service` in restartUnits/reloadUnits is a template instance, but home-manager applies changes per template. List `foo@.service` instead, which restarts or reloads all of its instances."
      ];
    };
  };

  mismatches = lib.filter (x: x != null) (
    lib.mapAttrsToList (
      name: c:
      let
        config = eval c.module;
        got = {
          assertions = failed config;
          warnings = ownWarnings config;
        };
        expected = { inherit (c) assertions warnings; };
      in
      if got == expected then
        null
      else
        "${name}:\n    expected: ${builtins.toJSON expected}\n    got:      ${builtins.toJSON got}"
    ) cases
  );

  # Option values that should hold, by description.
  values =
    let
      config = eval {
        imports = [
          usesToken
          consumer
        ];
        age.secrets.token.restartUnits = [ "consumer.service" ];
      };
      # Without the store path references, which `hasInfix` (a regex) refuses.
      dropIn =
        builtins.unsafeDiscardStringContext
          config.xdg.configFile."systemd/user/consumer.service.d/agenix-extras.conf".text;
    in
    {
      "templates render in agenix.service" =
        lib.hasInfix "ExecStartPost="
          config.xdg.configFile."systemd/user/agenix.service.d/agenix-extras-render.conf".text;
      # The hooks are a drop-in, so other Exec*Post commands don't conflict.
      "agenix.service can have its own ExecStartPost" =
        (eval {
          imports = [ usesToken ];
          systemd.user.services.agenix.Service.ExecStartPost = "/run/current-system/sw/bin/true";
        }).systemd.user.services.agenix.Service.ExecStartPost == "/run/current-system/sw/bin/true";
      "the drop-in orders the unit after agenix.service" = lib.hasInfix "After=agenix.service" dropIn;
      "the drop-in pulls in agenix.service" = lib.hasInfix "Wants=agenix.service" dropIn;
      # Without agenix (and so agenix.service), rendered files are still
      # removed on activation.
      "templates are cleaned up without agenix" =
        (eval { age.secrets = lib.mkForce { }; }).home.activation ? agenix-extras;
      "the drop-in restarts the unit when the .age file changes" =
        lib.hasInfix (builtins.unsafeDiscardStringContext "X-Restart-Triggers=${./secrets/api-token.age}") dropIn;
      "the default path is under XDG_RUNTIME_DIR" =
        config.age.templates.t.path == "\${XDG_RUNTIME_DIR}/agenix-extras/t";
    };

  errors =
    mismatches
    ++ lib.mapAttrsToList (name: _: "does not hold: ${name}") (lib.filterAttrs (_: ok: !ok) values);
in

assert lib.assertMsg (errors == [ ]) (
  "agenix-extras home-manager eval tests failed:\n  " + lib.concatStringsSep "\n  " errors
);
pkgs.writeText "agenix-extras-eval-home" "ok"
