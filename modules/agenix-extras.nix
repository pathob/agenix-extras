{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.age;
  extras = import ./lib.nix { inherit lib pkgs; };
  inherit (extras.forConfig cfg)
    secrets
    templates
    triggeredUnits
    dropInText
    templatePaths
    renderArgs
    assertions
    ;

  # Same detection agenix uses to decide between activation scripts and
  # systemd units.
  sysusersEnabled =
    options.systemd ? sysusers
    && (
      config.systemd.sysusers.enable || (options.services ? userborn && config.services.userborn.enable)
    );

  users = config.users.users;

  # Default location for rendered templates. Deliberately outside agenix's
  # generation directories: agenix swaps `/run/agenix` to a fresh, empty
  # generation before templates can be rendered, which would leave rendered
  # files missing for the rest of activation, and for good if rendering
  # fails. Like agenix's own secrets, this is a ramfs so plaintext is never
  # swapped to disk.
  renderedDir = "/run/agenix-extras";

  unitOptions = extras.unitListOptions {
    units = "Units";
    switch = "switch-to-configuration";
    example = [ "nginx.service" ];
    changes = "this template";
  };

  templateType = lib.types.submodule (
    { name, config, ... }:
    {
      options =
        extras.templateOptions {
          inherit
            name
            config
            renderedDir
            unitOptions
            ;
        }
        // {
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
        };
    }
  );

  renderOne = extras.mkRenderOne {
    chown = true;
  };

  renderTemplate =
    tpl:
    let
      args =
        lib.take 4 (renderArgs tpl)
        ++ [
          tpl.owner
          tpl.group
        ]
        ++ lib.drop 4 (renderArgs tpl);
      render = ''
        ${renderOne} ${lib.escapeShellArgs args} || {
          printf '[agenix-extras] failed to render %s\n' ${lib.escapeShellArg tpl.name} >&2
          failed=1
        }
      '';
    in
    # Decided on where the file is actually written (see `resolve`), so
    # symlinks such as /var/run -> /run can't get around these checks; a path
    # that can't be resolved counts as the directory itself.
    #
    # - Never replace the default directory itself, by its canonical path or
    #   its own entry (which may be a symlink to it).
    # - Never write into it without the ramfs mounted there: it would end up
    #   on /run, which can be swapped to disk.
    ''
      dest=$(resolve ${lib.escapeShellArg tpl.path}) || dest=$dir
      if [[ $dest == "$dir" || $dest == "$root" ]]; then
        printf '[agenix-extras] not rendering %s: %s is the template directory\n' ${lib.escapeShellArg tpl.name} ${lib.escapeShellArg tpl.path} >&2
        failed=1
      elif (( ! mounted )) && [[ $dest == "$dir"/* ]]; then
        printf '[agenix-extras] not rendering %s: %s is not mounted\n' ${lib.escapeShellArg tpl.name} "$dir" >&2
        failed=1
      else
        ${render}
      fi
    '';

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
    mounted=0

    ${extras.resolveFunction}

    # The default directory, canonical so the checks below compare like with
    # like even if it is a symlink (and so `find` lists its contents), and its
    # own entry, which a template must never replace. Without them, nothing
    # can be checked safely, so nothing is rendered.
    dir=$(realpath -m -- ${lib.escapeShellArg renderedDir}) && root=$(resolve ${lib.escapeShellArg renderedDir}) || {
      printf '[agenix-extras] cannot resolve %s\n' ${lib.escapeShellArg renderedDir} >&2
      exit 1
    }

    # If the ramfs can't be mounted, templates at other paths are still
    # rendered; the ones in the default directory are skipped.
    ${lib.optionalString (templates != { }) ''
      if mountpoint -q "$dir" || { mkdir -p "$dir" && mount -t ramfs none "$dir" -o nodev,nosuid,mode=0751; }; then
        mounted=1
        chown root:root "$dir"
        chmod 0751 "$dir"
      else
        printf '[agenix-extras] failed to mount ramfs at %s\n' "$dir" >&2
        failed=1
      fi
    ''}

    if mountpoint -q "$dir"; then
      ${extras.pruneSnippet {
        inherit templatePaths;
        expandPaths = false;
      }}
    fi

    ${lib.concatMapStringsSep "\n" renderTemplate (lib.attrValues templates)}

    exit $failed
  '';

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
      path = pkgs.writeText "agenix-extras-${lib.strings.sanitizeDerivationName u}.conf" (
        dropInText u (
          lib.optionalString (extras.isInstanceName u && !definedByNixOS u) ''
            # switch-to-configuration stops an instance once its last drop-in
            # is removed. Ours doesn't make the instance NixOS-managed, so
            # dropping the unit from restartUnits/reloadUnits must not stop it.
            # (Instances NixOS defines keep the default, so removing them still
            # stops them. Removing the template while this instance is still
            # listed leaves it running.)
            X-StopOnRemoval=false
          ''
        )
      );
    }) (lib.filter extras.isUnitName triggeredUnits)
  );

in

{
  options.age = {
    templates = lib.mkOption {
      type = lib.types.attrsOf templateType;
      default = { };
      description = "Templates rendered with secret values substituted at activation time.";
    };

    placeholder = extras.placeholderOption;

    secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = extras.unitListOptions {
            units = "Units";
            switch = "switch-to-configuration";
            example = [ "nginx.service" ];
            changes = "this secret's `.age` file";
          };
        }
      );
    };
  };

  config = {
    age.placeholder = lib.mapAttrs (name: _: extras.placeholderFor name) secrets;

    assertions = assertions {
      isAbsolute = lib.hasPrefix "/";
      inherit renderedDir;
    };

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
