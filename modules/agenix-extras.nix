{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.age;

  # Same detection agenix uses to decide between activation scripts and
  # systemd units.
  sysusersEnabled =
    options.systemd ? sysusers
    && (
      config.systemd.sysusers.enable || (options.services ? userborn && config.services.userborn.enable)
    );

  templates = cfg.templates;
  secrets = cfg.secrets;
  users = config.users.users;

  placeholderFor = name: "<AGENIX:${builtins.hashString "sha256" name}:PLACEHOLDER>";

  # The store path Nix evaluation should track for `restartTriggers` /
  # `reloadTriggers`. For agenix secrets that's the encrypted `.age` file (the
  # plaintext only exists at runtime, but its inputs are the ciphertext +
  # identity, and the identity is fixed per host so the ciphertext is what
  # changes). For templates it's the source file plus every referenced secret's
  # `.age`, because a template's output depends on both.
  secretTrigger = name: toStorePath secrets.${name}.file;

  # Copy a Nix path into the store, as NixOS's own restartTriggers do. Plain
  # `toString` keeps a path outside the store (e.g. `/etc/nixos/x.age` in a
  # non-flake config) as-is, so editing the file wouldn't change the trigger.
  toStorePath = x: if lib.isPath x then "${x}" else x;
  templateTriggers = tpl: [ (templateSource tpl) ] ++ map secretTrigger (referencedSecrets tpl);

  # Plain text of a template, for placeholder discovery at eval time. Setting
  # neither `file` nor `content` fails an assertion, but the assertions
  # themselves scan the text, so that case reads as empty here.
  templateText =
    tpl: if tpl.file != null then builtins.readFile tpl.file else lib.defaultTo "" tpl.content;

  # Names of the secrets whose placeholder appears in the template.
  referencedSecrets =
    tpl:
    let
      text = templateText tpl;
    in
    lib.filter (n: lib.hasInfix (placeholderFor n) text) (lib.attrNames secrets);

  templateSource =
    tpl:
    if tpl.file != null then
      toStorePath tpl.file
    else
      pkgs.writeText "agenix-template-${lib.strings.sanitizeDerivationName tpl.name}" (
        lib.defaultTo "" tpl.content
      );

  # Default location for rendered templates. Deliberately outside agenix's
  # generation directories: agenix swaps `/run/agenix` to a fresh, empty
  # generation before templates can be rendered, which would leave rendered
  # files missing for the rest of activation, and for good if rendering
  # fails. Like agenix's own secrets, this is a ramfs so plaintext is never
  # swapped to disk.
  renderedDir = "/run/agenix-extras";

  templateType = lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "File name of the rendered template.";
        };

        path = lib.mkOption {
          type = lib.types.str;
          default = "${renderedDir}/${config.name}";
          defaultText = lib.literalExpression ''"${renderedDir}/''${config.name}"'';
          description = ''
            Path where the rendered file is written. The file is replaced
            atomically, and kept as-is if rendering fails.

            Files in the default directory that no longer belong to a template
            are removed on activation. Files at other paths are not.
          '';
        };

        content = lib.mkOption {
          type = lib.types.nullOr lib.types.lines;
          default = null;
          description = ''
            Template body. Exactly one of `content` and `file` must be set.
            Reference decrypted secrets via
            `''${config.age.placeholder.<secret-name>}`; the placeholder is
            substituted with the secret's plaintext at activation time.
          '';
        };

        file = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Path to a file used as the template, as an alternative to `content`.
            The file is read at evaluation time to find its placeholders, so
            prefer `builtins.toFile` to a derivation such as `pkgs.writeText`,
            which would need import from derivation.
          '';
        };

        mode = lib.mkOption {
          type = lib.types.str;
          default = "0400";
          description = "Permissions of the rendered file (chmod format).";
        };

        owner = lib.mkOption {
          type = lib.types.str;
          default = "0";
          description = "Owner of the rendered file.";
        };

        group = lib.mkOption {
          type = lib.types.str;
          # Same default as agenix uses for secrets.
          default = (lib.findFirst (u: u.name == config.owner) { } (lib.attrValues users)).group or "0";
          defaultText = lib.literalExpression ''
            (findFirst (u: u.name == config.owner) { } (attrValues users)).group or "0"
          '';
          description = "Group of the rendered file. Defaults to the primary group of `owner`, like agenix secrets.";
        };

        restartUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "nginx.service" ];
          description = "Units restarted by switch-to-configuration when this template changes.";
        };

        reloadUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "nginx.service" ];
          description = "Units reloaded (or restarted if no reload defined) when this template changes.";
        };
      };
    }
  );

  # Render one template: substitute every placeholder its source references
  # with the contents of the corresponding decrypted secret file, then move
  # the result into place.
  #
  # Usage: render-one NAME SRC DEST MODE OWNER GROUP [PLACEHOLDER SECRET-PATH]...
  #
  # This is a separate process rather than inline shell so that `set -e` is
  # scoped to a single template: bash ignores `set -e` inside anything on the
  # left of `||`, subshells included, and setting it in the activation script
  # itself would leak into every snippet that runs after ours.
  renderOne = pkgs.writeShellScript "agenix-extras-render-one" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.replace-secret
      ]
    }

    name=$1 src=$2 dest=$3 mode=$4 owner=$5 group=$6
    shift 6

    printf '[agenix-extras] rendering %s -> %s\n' "$name" "$dest"
    dir=$(dirname "$dest")
    mkdir -p "$dir"
    tmp=$(mktemp -p "$dir" ".$(basename "$dest").XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    cat "$src" > "$tmp"
    while (( $# )); do
      replace-secret "$1" "$2" "$tmp"
      shift 2
    done
    chmod "$mode" "$tmp"
    chown "$owner:$group" "$tmp"
    # -T: fail if `dest` is a directory instead of moving the file into it.
    mv -fT "$tmp" "$dest"
    trap - EXIT
  '';

  renderTemplate =
    tpl:
    let
      args = [
        tpl.name
        (templateSource tpl)
        tpl.path
        tpl.mode
        tpl.owner
        tpl.group
      ]
      ++ lib.concatMap (n: [
        (placeholderFor n)
        secrets.${n}.path
      ]) (referencedSecrets tpl);
    in
    ''
      ${renderOne} ${lib.escapeShellArgs args} || {
        printf '[agenix-extras] failed to render %s\n' ${lib.escapeShellArg tpl.name} >&2
        failed=1
      }
    '';

  # Paths in `renderedDir` that belong to a current template. Anything else
  # in there is left over from a removed or renamed template.
  renderedManifest = pkgs.writeText "agenix-extras-rendered" (
    lib.concatLines (
      lib.filter (lib.hasPrefix "${renderedDir}/") (lib.mapAttrsToList (_: t: t.path) templates)
    )
  );

  # Render every template, carrying on past failures so one broken template
  # doesn't keep the others from being updated. Exits non-zero if any failed.
  renderAll = pkgs.writeShellScript "agenix-extras-render" ''
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.util-linux
      ]
    }
    failed=0
    dir=${lib.escapeShellArg renderedDir}

    ${lib.optionalString (templates != { }) ''
      mkdir -p "$dir"
      if ! mountpoint -q "$dir"; then
        mount -t ramfs none "$dir" -o nodev,nosuid,mode=0751 || {
          printf '[agenix-extras] failed to mount ramfs at %s\n' "$dir" >&2
          exit 1
        }
      fi
      chown root:root "$dir"
      chmod 0751 "$dir"
    ''}

    # Prune before rendering, so a stale file or directory can't be in the way
    # when a template's path turns into a directory or vice versa.
    if mountpoint -q "$dir"; then
      while IFS= read -r -d "" f; do
        if ! grep -Fxq -- "$f" ${renderedManifest}; then
          printf '[agenix-extras] removing stale %s\n' "$f"
          rm -f -- "$f"
        fi
      done < <(find "$dir" -mindepth 1 ! -type d -print0)
      find "$dir" -mindepth 1 -depth -type d -empty -delete
    fi

    ${lib.concatMapStringsSep "\n" renderTemplate (lib.attrValues templates)}

    exit $failed
  '';

  # For every unit named in a `restartUnits` / `reloadUnits` option, the store
  # paths whose change should restart / reload it.
  unitTriggers =
    field:
    lib.zipAttrsWith (_: vs: lib.unique (lib.concatLists vs)) (
      lib.concatMap (s: map (u: { ${u} = [ (toStorePath s.file) ]; }) s.${field}) (lib.attrValues secrets)
      ++ lib.concatMap (t: map (u: { ${u} = templateTriggers t; }) t.${field}) (lib.attrValues templates)
    );
  restartTriggers = unitTriggers "restartUnits";
  reloadTriggers = unitTriggers "reloadUnits";
  triggeredUnits = lib.unique (lib.attrNames restartTriggers ++ lib.attrNames reloadTriggers);

  # `foo.service`, `foo@bar.service`, `foo@.service`, ...
  isUnitName =
    u:
    builtins.match "[^/]+\\.(service|socket|device|mount|automount|swap|target|path|timer|slice|scope)" u
    != null;
  isInstanceName = u: builtins.match "[^/]*@[^/]+\\.[a-z]+" u != null;

  # Whether the NixOS config itself defines the unit (as opposed to it only
  # getting our drop-in). `systemd.units` covers both raw units and those
  # generated from `systemd.services` etc. Safe to evaluate here: the drop-ins
  # go through `systemd.packages`, which `systemd.units` doesn't depend on.
  definedByNixOS = u: config.systemd.units ? ${u};

  # The triggers are attached as a drop-in, `<unit>.d/agenix-extras.conf`,
  # rather than through `systemd.services.<name>.restartTriggers`. Defining
  # `systemd.services.<name>` for a unit that neither NixOS nor a package
  # defines generates a stub unit file with no ExecStart. For a template
  # instance (`foo@bar.service`) that stub shadows the template and the
  # instance can no longer be started. A drop-in only adds keys to whatever
  # unit exists, whether it comes from NixOS, a package or a template, and
  # switch-to-configuration reads drop-ins when deciding what to restart or
  # reload.
  triggerDropIns = pkgs.linkFarm "agenix-extras-unit-triggers" (
    map (u: {
      name = "etc/systemd/system/${u}.d/agenix-extras.conf";
      path = pkgs.writeText "agenix-extras-${lib.strings.sanitizeDerivationName u}.conf" ''
        [Unit]
        ${lib.optionalString (restartTriggers ? ${u}) "X-Restart-Triggers=${toString restartTriggers.${u}}"}
        ${lib.optionalString (reloadTriggers ? ${u}) "X-Reload-Triggers=${toString reloadTriggers.${u}}"}
        ${lib.optionalString (isInstanceName u && !definedByNixOS u) ''
          # switch-to-configuration stops an instance once its last drop-in
          # is removed. Ours doesn't make the instance NixOS-managed, so
          # dropping the unit from restartUnits/reloadUnits must not stop it.
          # (Instances NixOS defines keep the default, so removing them still
          # stops them. Removing the template while this instance is still
          # listed leaves it running.)
          X-StopOnRemoval=false
        ''}
      '';
    }) (lib.filter isUnitName triggeredUnits)
  );

in

{
  options.age = {
    templates = lib.mkOption {
      type = lib.types.attrsOf templateType;
      default = { };
      description = "Templates rendered with secret values substituted at activation time.";
    };

    placeholder = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        One placeholder string per secret in {option}`age.secrets`, for use in
        {option}`age.templates.<name>.content` (or a template `file`). Each one is
        replaced with the secret's decrypted contents when the template is
        rendered, with leading and trailing newlines stripped. The placeholders
        themselves contain no secret material, so they are safe in the Nix
        store.
      '';
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
    age.placeholder = lib.mapAttrs (name: _: placeholderFor name) secrets;

    assertions =
      lib.mapAttrsToList (name: t: {
        assertion = (t.file == null) != (t.content == null);
        message = "age.templates.${name}: set exactly one of `file` and `content`.";
      }) templates
      # Normalised, because stale files are pruned by comparing against `path`
      # verbatim: `/run/agenix-extras/./x` would be rendered and then deleted.
      ++ lib.mapAttrsToList (name: t: {
        assertion =
          lib.hasPrefix "/" t.path
          && builtins.match ".*(//|/\\./|/\\.\\./).*|.*/(\\.|\\.\\.)?" t.path == null;
        message = "age.templates.${name}.path must be an absolute path without `.`, `..` or empty components; got: ${t.path}";
      }) templates
      ++ lib.mapAttrsToList (path: names: {
        assertion = lib.length names == 1;
        message = "age.templates: ${lib.concatStringsSep ", " names} all render to ${path}.";
      }) (lib.groupBy' (names: n: names ++ [ n ]) [ ] (n: templates.${n}.path) (lib.attrNames templates))
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: t:
          map (n: {
            assertion = (cfg.enable or true) && (secrets.${n}.enable or true);
            # Name the secret's own flag first: agenix's `age.enable` defaults
            # to "any secret enabled", so it is a consequence, not the cause.
            message = "age.templates.${name} uses age.secrets.${n}, which is not decrypted because ${
              if !(secrets.${n}.enable or true) then "age.secrets.${n}.enable" else "age.enable"
            } is false.";
          }) (referencedSecrets t)
        ) templates
      )
      ++ map (u: {
        assertion = isUnitName u;
        message = "agenix-extras: `${u}` in restartUnits/reloadUnits is not a systemd unit name (expected e.g. `${u}.service`).";
      }) triggeredUnits;

    # Runs even without templates so that removing the last one still prunes
    # its rendered file.
    system.activationScripts.agenix-extras = lib.mkIf (!sysusersEnabled) {
      # A failure here is recorded by the activation script's ERR trap
      # (marking this snippet and the switch as failed) without stopping the
      # snippets that run after it.
      text = "${renderAll}";
      # `agenix` (decrypted and chowned) only exists while agenix is enabled.
      deps = [
        "users"
        "groups"
      ]
      ++ lib.optional (cfg.enable or true) "agenix";
    };

    systemd = lib.mkMerge [
      { packages = lib.optional (triggeredUnits != [ ]) triggerDropIns; }

      # Under systemd-sysusers/userborn agenix decrypts from systemd units in
      # sysinit.target instead of activation scripts, and users only exist
      # once sysusers has run, so render from a unit ordered after both.
      #
      # On a switch, units that changed are stopped before activation and
      # started again later, but reloads happen before that. Like
      # systemd-sysusers and userborn, decryption, chown and rendering are
      # therefore part of sysinit-reactivation.target, which
      # switch-to-configuration restarts (starting whatever was stopped, in
      # order) before it reloads anything. Otherwise consumers in reloadUnits
      # would reload the previous file.
      (lib.mkIf sysusersEnabled {
        services = {
          agenix-extras = {
            description = "Render agenix-extras templates";
            wantedBy = [ "sysinit.target" ];
            requiredBy = [ "sysinit-reactivation.target" ];
            # Without default dependencies, sysinit.target isn't ordered after
            # us automatically; normal services must wait for rendering.
            before = [
              "sysinit.target"
              "sysinit-reactivation.target"
            ];
            after = [
              "systemd-sysusers.service"
              "agenix-install-secrets.service"
              "agenix-chown.service"
            ];
            # Re-render whenever agenix re-decrypts, in the same transaction and
            # therefore after it. The script itself changes with the templates.
            partOf = [ "agenix-install-secrets.service" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = renderAll;
            };
          };
        }
        // lib.genAttrs [ "agenix-install-secrets" "agenix-chown" ] (
          _:
          lib.mkIf (cfg.enable or true) {
            requiredBy = [ "sysinit-reactivation.target" ];
            before = [ "sysinit-reactivation.target" ];
          }
        );
      })
    ];
  };
}
