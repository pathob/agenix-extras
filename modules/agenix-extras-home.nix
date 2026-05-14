{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.age;
  extras = import ./lib.nix { inherit lib pkgs cfg; };

  # Home-manager doesn't expose `restartTriggers` directly on user units, so
  # we encode them as an `X-Restart-Triggers` key in the [Service] section.
  # When the trigger inputs change, the rendered unit file's content changes,
  # and home-manager's switch detects that and restarts the unit.
  triggersToServiceKey =
    triggers:
    let
      content = lib.concatStringsSep "\n" (map toString triggers);
    in
    "${pkgs.writeText "X-Restart-Triggers" content}";

  # `extras.triggersFor` already groups by kind (services/sockets/timers/…).
  # Home-manager mirrors that under `systemd.user.<kind>` with the same names,
  # so we can hand the grouped attrset straight through, just translating each
  # leaf into a `Service.<TriggerKey> = path-to-content` entry.
  attachTriggers =
    field: triggerKey:
    lib.mapAttrs (
      _: kindAttrs:
      lib.mapAttrs (
        _: u: { Service.${triggerKey} = triggersToServiceKey u.triggers; }
      ) kindAttrs
    ) (extras.triggersFor field "triggers");

  # All (kind, name) tuples that this module is told to attach triggers to.
  allTargetedUnits =
    let
      grouped = lib.recursiveUpdate (extras.triggersFor "restartUnits" "x") (
        extras.triggersFor "reloadUnits" "x"
      );
    in
    lib.concatLists (
      lib.mapAttrsToList (kind: units: map (n: { inherit kind n; }) (lib.attrNames units)) grouped
    );

  # A targeted unit "exists" if, in the merged config, its declared body has
  # any key beyond the X-*-Triggers entries that we ourselves contribute. If
  # the only contents are our triggers, the user named a unit that nothing
  # else in their HM config declares — we'd produce an invalid stub.
  ghostUnits = lib.filter (
    { kind, n }:
    let
      unit = config.systemd.user.${kind}.${n} or null;
      hasRealBody =
        unit != null
        && (
          (unit.Unit or { }) != { }
          || (unit.Install or { }) != { }
          || lib.any (k: !(lib.hasPrefix "X-" k)) (lib.attrNames (unit.Service or { }))
        );
    in
    !hasRealBody
  ) allTargetedUnits;

  hasLinuxPlatform = pkgs.stdenv.hostPlatform.isLinux;
in

{
  options.age = {
    templates = lib.mkOption {
      type = lib.types.attrsOf extras.templateType;
      default = { };
      description = "Templates rendered with secret values substituted at activation time.";
    };

    placeholder = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      internal = true;
      description = "Placeholder strings substituted with secret plaintext.";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            restartUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "mbsync.service" ];
              description = ''
                User systemd units restarted on switch when this secret's `.age`
                file changes. Only user units are supported (the home-manager
                module cannot touch system units).
              '';
            };
            reloadUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "mbsync.service" ];
              description = ''
                User systemd units reloaded on switch when this secret's `.age`
                file changes. Only user units are supported.
              '';
            };
          };
        }
      );
    };
  };

  config = {
    age.placeholder = lib.mapAttrs (name: _: extras.placeholderFor name) cfg.secrets;

    assertions = extras.commonAssertions ++ extras.pathAssertions { pathsExpand = true; } ++ [
      {
        assertion = hasLinuxPlatform;
        message = ''
          agenix-extras home-manager module currently only supports Linux.
          Darwin uses launchd for agenix activation and would need a separate
          integration.
        '';
      }
    ];

    warnings =
      extras.commonWarnings
      ++ lib.optional (ghostUnits != [ ]) (
        "agenix-extras (home-manager): the following units are referenced by"
        + " restartUnits/reloadUnits but not declared in the home-manager"
        + " config; they would be written as stub units with only"
        + " X-Restart-Triggers and rejected by systemd. Declare them in"
        + " systemd.user.<kind>.<name> or remove the reference. Bad units:\n  "
        + lib.concatStringsSep "\n  " (map (g: "${g.kind}.${g.n}") ghostUnits)
      );

    # Render templates in a user systemd oneshot that runs after agenix has
    # decrypted the secrets.
    systemd.user = lib.mkMerge [
      (lib.mkIf (cfg.templates != { }) {
        services.agenix-extras = {
          Unit = {
            Description = "agenix-extras template rendering";
            After = [ "agenix.service" ];
            Requires = [ "agenix.service" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${pkgs.writeShellScript "agenix-extras-render" (
              extras.activationScriptText {
                chmodOwner = false;
                pathsExpand = true;
              }
            )}";
            RemainAfterExit = true;
          };
          Install.WantedBy = [ "default.target" ];
        };
      })
      (attachTriggers "restartUnits" "X-Restart-Triggers")
      (attachTriggers "reloadUnits" "X-Reload-Triggers")
    ];
  };
}
