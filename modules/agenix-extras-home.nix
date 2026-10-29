# The home-manager counterpart of agenix-extras.nix, on top of agenix's
# home-manager module: templates rendered right after agenix decrypts, and
# restartUnits/reloadUnits for user units.
{
  config,
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

  isLinux = pkgs.stdenv.hostPlatform.isLinux;

  # Whether the activation runs agenix.service ahead of sd-switch (see there).
  renderEarly =
    cfg.enable && (templates != { } || triggeredUnits != [ ]) && config.systemd.user.startServices;

  # Next to agenix's own home-manager secrets, in the per-user runtime
  # directory, but outside agenix's generation directories for the same
  # reason as on NixOS: agenix replaces those on every run, which would leave
  # rendered files missing until they are rendered again.
  renderedDir = "\${XDG_RUNTIME_DIR}/agenix-extras";

  unitOptions = extras.unitListOptions {
    units = "User units";
    switch = "home-manager";
    example = [ "mbsync.service" ];
    changes = "this template";
  };

  templateType = lib.types.submodule (
    { name, config, ... }:
    {
      options = extras.templateOptions {
        inherit
          name
          config
          renderedDir
          unitOptions
          ;
      };
    }
  );

  # Paths here are shell expressions like agenix's own (`${XDG_RUNTIME_DIR}`
  # and the like), expanded when rendering. No chown: rendering runs as the
  # user.
  renderOne = extras.mkRenderOne {
    chown = false;
  };

  # Render every template, carrying on past failures so one broken template
  # doesn't keep the others from being updated. Exits non-zero if any failed.
  # With `--prune-only`, only removes stale files.
  renderAll = pkgs.writeShellScript "agenix-extras-render" ''
    ${extras.captureEnvSnippet}
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
      ]
    }
    failed=0
    pruneOnly=0
    [[ ''${1:-} == --prune-only ]] && pruneOnly=1

    ${extras.expandFunction}
    ${extras.resolveFunction}

    dir=$(expand ${lib.escapeShellArg renderedDir}) || exit 1
    # Stale files in it are removed, so never follow a symlink there (to
    # $HOME, say) into a directory that isn't ours.
    if [[ -L ''${dir%/} ]]; then
      printf '[agenix-extras] %s is a symlink, not rendering anything\n' "$dir" >&2
      exit 1
    fi
    dir=$(realpath -m -- "$dir") || exit 1

    ${lib.optionalString (templates != { }) ''
      if (( ! pruneOnly )); then
        # Private to the user, like agenix's own directory.
        mkdir -p "$dir" && chmod 0700 "$dir" || failed=1
      fi
    ''}

    if [[ -d $dir ]]; then
      ${extras.pruneSnippet {
        inherit templatePaths;
        expandPaths = true;
      }}
    fi

    # Like render-one, but expands the destination and the secret paths
    # first, here, from the same environment the checks above used.
    renderExpanded() {
      local args=("$1" "$2") x
      x=$(expand "$3") || return 1
      args+=("$x" "$4")
      shift 4
      while (( $# )); do
        x=$(expand "$2") || return 1
        args+=("$1" "$x")
        shift 2
      done
      ${renderOne} "''${args[@]}"
    }

    if (( ! pruneOnly )); then
      ${lib.concatMapStringsSep "\n" (tpl: ''
        renderExpanded ${lib.escapeShellArgs (renderArgs tpl)} || {
          printf '[agenix-extras] failed to render %s\n' ${lib.escapeShellArg tpl.name} >&2
          failed=1
        }
      '') (lib.attrValues templates)}
      :
    fi

    exit $failed
  '';

  # home-manager applies changes to user units with sd-switch, which only
  # looks at units home-manager itself manages (their unit files, including
  # those generated from `systemd.user.*`, are `xdg.configFile` entries), and
  # for a template instance only at the template's file and drop-ins.
  managedByHM = u: config.xdg.configFile ? "systemd/user/${u}";
  # `foo@bar.service` -> `foo@.service`
  templateOf =
    u:
    let
      # Up to the last suffix: instance names may contain dots.
      m = builtins.match "([^@]*@).*([.][a-z]+)" u;
    in
    "${builtins.elemAt m 0}${builtins.elemAt m 1}";
in

{
  options.age = {
    templates = lib.mkOption {
      type = lib.types.attrsOf templateType;
      default = { };
      description = "Templates rendered with secret values substituted when agenix decrypts the secrets.";
    };

    placeholder = extras.placeholderOption;

    secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = extras.unitListOptions {
            units = "User units";
            switch = "home-manager";
            example = [ "mbsync.service" ];
            changes = "this secret's `.age` file";
          };
        }
      );
    };
  };

  config = {
    age.placeholder = lib.mapAttrs (name: _: extras.placeholderFor name) secrets;

    assertions =
      assertions {
        # Absolute, or starting with a variable such as `${XDG_RUNTIME_DIR}`.
        isAbsolute =
          p:
          lib.hasPrefix "/" p
          || builtins.match "[$]([{][A-Za-z_][A-Za-z0-9_]*[}]|[A-Za-z_][A-Za-z0-9_]*)/.*" p != null;
        inherit renderedDir;
      }
      ++ [
        {
          assertion = templates == { } || cfg.enable;
          message = "age.templates: templates are rendered by agenix's agenix.service, which only exists while age.enable is true (by default, when at least one secret is enabled).";
        }
        {
          assertion = (templates == { } && triggeredUnits == [ ]) || isLinux;
          message = "agenix-extras' home-manager module only supports Linux; on macOS agenix runs from launchd, which it doesn't hook into.";
        }
        {
          assertion = (templates == { } && triggeredUnits == [ ]) || (config.systemd.user.enable or true);
          message = "agenix-extras: templates and restartUnits/reloadUnits need home-manager's systemd integration (systemd.user.enable), which agenix.service and the units come from.";
        }
      ];

    warnings = lib.concatMap (
      u:
      if extras.isInstanceName u then
        [
          "agenix-extras: `${u}` in restartUnits/reloadUnits is a template instance, but home-manager applies changes per template. List `${templateOf u}` instead, which restarts or reloads all of its instances."
        ]
      else
        lib.optional (!managedByHM u)
          "agenix-extras: `${u}` in restartUnits/reloadUnits isn't defined in this home-manager configuration, and home-manager only restarts or reloads units it manages."
    ) (lib.filter extras.isUnitName triggeredUnits);

    # On a switch, sd-switch queues reloads, restarts and starts together, and
    # systemd doesn't hold back a reload until another unit has started, so a
    # unit in reloadUnits would reload before agenix.service has re-rendered.
    # Like the NixOS module (sysinit-reactivation.target), run agenix.service
    # with the new units before that, so everything sd-switch does sees the
    # new files. sd-switch may then run it once more, which is harmless. This
    # only happens if sd-switch applies the units at all
    # (systemd.user.startServices) and there are templates or triggers.
    #
    # Otherwise, if agenix is disabled (e.g. the last secret and template were
    # just removed), agenix.service is gone, so the rendered files are removed
    # here; with no secrets, nothing can be mistaken for stale. While agenix
    # is enabled, that is up to agenix.service: what is still needed depends
    # on paths expanded in its environment, which this activation's may not
    # match.
    #
    # Failures are reported but don't abort the activation, like on NixOS: a
    # template that fails to render keeps its previous file.
    home.activation.agenix-extras = lib.mkIf (isLinux && (renderEarly || !cfg.enable)) (
      lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "linkGeneration" ] (
        if renderEarly then
          ''
            agenixExtrasSystemctl() {
              env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
                ${config.systemd.user.systemctlPath} --user "$@"
            }
            # Only with a running user manager; otherwise agenix.service runs
            # when it starts, before the units ordered after it. The command
            # exits non-zero for "degraded" too, so only its output counts.
            agenixExtrasState=$(agenixExtrasSystemctl is-system-running 2>/dev/null || true)
            if [[ $agenixExtrasState == running || $agenixExtrasState == degraded ]]; then
              run agenixExtrasSystemctl daemon-reload
              run agenixExtrasSystemctl start agenix.service \
                || warnEcho "agenix-extras: agenix.service failed, so templates may be out of date."
            fi
          ''
        else
          ''
            run env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" ${renderAll} --prune-only \
              || warnEcho "agenix-extras: couldn't remove stale templates."
          ''
      )
    );

    # Attach the triggers as `[Unit]` drop-ins, like the NixOS module, so that
    # no stub unit is ever created. `Wants=` and `After=agenix.service` make
    # the units start (at login, or when started on their own) and restart or
    # reload (on a switch, where sd-switch queues these jobs together) only
    # after the templates are rendered. Not `Requires=`: one secret that fails
    # to decrypt shouldn't keep units from starting with the previous files.
    xdg.configFile = lib.mkIf isLinux (
      lib.mkMerge [
        (lib.listToAttrs (
          map (
            u:
            lib.nameValuePair "systemd/user/${u}.d/agenix-extras.conf" {
              text = dropInText u ''
                Wants=agenix.service
                After=agenix.service
              '';
            }
          ) (lib.filter extras.isUnitName triggeredUnits)
        ))

        # Render as part of agenix's own unit, right after it decrypts. Every
        # run of agenix.service, at login and whenever home-manager starts it
        # again because its secrets or our templates changed, re-renders, and
        # nothing can see freshly decrypted secrets with stale templates.
        #
        # systemd skips ExecStartPost when decryption fails, but a template
        # removed in the same switch must still go: then ExecStopPost only
        # removes stale files (the others keep their previous contents).
        #
        # A drop-in (named apart from the trigger drop-ins above) rather than
        # `systemd.user.services.agenix.Service.*`, so it adds to whatever
        # Exec*Post commands the unit already has instead of conflicting.
        (lib.mkIf cfg.enable {
          "systemd/user/agenix.service.d/agenix-extras-render.conf".text = ''
            [Service]
            ExecStartPost=${renderAll}
            ExecStopPost=${pkgs.writeShellScript "agenix-extras-cleanup" ''
              [[ ''${SERVICE_RESULT:-} == success ]] && exit 0
              exec ${renderAll} --prune-only
            ''}
          '';
        })
      ]
    );
  };
}
