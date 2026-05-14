{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.age;
  extras = import ./lib.nix { inherit lib pkgs cfg; };
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
              example = [ "nginx.service" ];
              description = "Units restarted by switch-to-configuration when this secret's `.age` file changes.";
            };
            reloadUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "nginx.service" ];
              description = "Units reloaded (or restarted) when this secret's `.age` file changes.";
            };
          };
        }
      );
    };
  };

  config = {
    age.placeholder = lib.mapAttrs (name: _: extras.placeholderFor name) cfg.secrets;

    assertions = extras.commonAssertions ++ extras.pathAssertions { pathsExpand = false; };
    warnings = extras.commonWarnings;

    system.activationScripts.agenix-extras = lib.mkIf (cfg.templates != { }) {
      text = extras.activationScriptText { chmodOwner = true; };
      deps = [ "agenix" ];
    };

    systemd = lib.mkMerge [
      (extras.triggersFor "restartUnits" "restartTriggers")
      (extras.triggersFor "reloadUnits" "reloadTriggers")
    ];
  };
}
