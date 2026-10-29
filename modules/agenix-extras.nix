{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.age;

  templates = cfg.templates;
  secrets = cfg.secrets;

  placeholderFor = name: "<AGENIX:${builtins.hashString "sha256" name}:PLACEHOLDER>";

  # The store path Nix evaluation should track for `restartTriggers` /
  # `reloadTriggers`. For agenix secrets that's the encrypted `.age` file (the
  # plaintext only exists at runtime, but its inputs are the ciphertext +
  # identity, and the identity is fixed per host so the ciphertext is what
  # changes). For templates it's the source file plus every referenced secret's
  # `.age`, because a template's output depends on both.
  secretTrigger = name: secrets.${name}.file;
  templateTriggers = tpl: [ (templateSource tpl) ] ++ map secretTrigger (referencedSecrets tpl);

  # Plain text of a template, for placeholder discovery at eval time.
  templateText = tpl: if tpl.file != null then builtins.readFile tpl.file else tpl.content;

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
      tpl.file
    else
      pkgs.writeText "agenix-template-${lib.strings.sanitizeDerivationName tpl.name}" tpl.content;

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
          type = lib.types.lines;
          default = "";
          description = ''
            Template body. Reference decrypted secrets via
            `''${config.age.placeholder.<secret-name>}`; the placeholder is
            substituted with the secret's plaintext at activation time.
          '';
        };

        file = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Path to a file used as the template. When set, `content` is ignored.
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
          default = "0";
          description = "Group of the rendered file.";
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

  # Invert: for each named unit, collect every store path that should trigger
  # it (the secret's `.age` ciphertext, or for a template its source + every
  # secret it references). We then plant those into the unit's standard
  # `restartTriggers` / `reloadTriggers`, which switch-to-configuration
  # honours at eval time — no runtime hash tracking needed.
  unitKind =
    unit:
    let
      parts = lib.splitString "." unit;
    in
    if lib.length parts < 2 then null else lib.last parts;

  unitName =
    unit:
    let
      parts = lib.splitString "." unit;
    in
    lib.concatStringsSep "." (lib.init parts);

  kindToAttr = {
    service = "services";
    socket = "sockets";
    timer = "timers";
    path = "paths";
    target = "targets";
    mount = "mounts";
    automount = "automounts";
    slice = "slices";
  };

  # `null` or an absent kind returns null. Guards against the fact that
  # `attrs.${null}` throws at the interpolation step, before `or` can save us.
  unitSubtree =
    unit:
    let
      kind = unitKind unit;
    in
    if kind == null then null else kindToAttr.${kind} or null;

  # Build `{ services.<n>.restartTriggers = [...]; sockets.<n>... }`.
  # We accumulate manually because `recursiveUpdate` overwrites list values.
  triggersFor =
    field: triggersField:
    let
      entries =
        lib.concatMap (
          s:
          map (u: {
            inherit u;
            triggers = [ s.file ];
          }) (s.${field} or [ ])
        ) (lib.attrValues secrets)
        ++ lib.concatMap (
          t:
          map (u: {
            inherit u;
            triggers = templateTriggers t;
          }) t.${field}
        ) (lib.attrValues templates);

      grouped = lib.foldl' (
        acc: e:
        let
          subtree = unitSubtree e.u;
        in
        if subtree == null then
          acc
        else
          let
            n = unitName e.u;
            existing = acc.${subtree}.${n}.${triggersField} or [ ];
          in
          acc
          // {
            ${subtree} = (acc.${subtree} or { }) // {
              ${n} = (acc.${subtree}.${n} or { }) // {
                ${triggersField} = existing ++ e.triggers;
              };
            };
          }
      ) { } entries;
    in
    lib.mapAttrs (
      _: kindAttrs:
      lib.mapAttrs (_: unit: unit // { ${triggersField} = lib.unique unit.${triggersField}; }) kindAttrs
    ) grouped;
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
    age.placeholder = lib.mapAttrs (name: _: placeholderFor name) secrets;

    assertions =
      lib.mapAttrsToList (name: t: {
        assertion = !(t.file != null && t.content != "");
        message = "age.templates.${name}: set either `file` or `content`, not both.";
      }) templates
      # Normalised, because stale files are pruned by comparing against `path`
      # verbatim: `/run/agenix-extras/./x` would be rendered and then deleted.
      ++ lib.mapAttrsToList (name: t: {
        assertion =
          lib.hasPrefix "/" t.path
          && builtins.match ".*(//|/\\./|/\\.\\./).*|.*/(\\.|\\.\\.)?" t.path == null;
        message = "age.templates.${name}.path must be an absolute path without `.`, `..` or empty components; got: ${t.path}";
      }) templates
      ++ [
        {
          assertion =
            let
              paths = lib.mapAttrsToList (_: t: t.path) templates;
            in
            lib.length paths == lib.length (lib.unique paths);
          message =
            "age.templates: multiple templates render to the same path:\n  "
            + lib.concatStringsSep "\n  " (lib.mapAttrsToList (n: t: "${n} -> ${t.path}") templates);
        }
      ];

    # Runs even without templates so that removing the last one still prunes
    # its rendered file.
    system.activationScripts.agenix-extras = {
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
      (triggersFor "restartUnits" "restartTriggers")
      (triggersFor "reloadUnits" "reloadTriggers")
    ];

    warnings =
      let
        bad = lib.filter (u: unitSubtree u == null) (
          lib.unique (
            lib.concatMap (s: (s.restartUnits or [ ]) ++ (s.reloadUnits or [ ])) (lib.attrValues secrets)
            ++ lib.concatMap (t: t.restartUnits ++ t.reloadUnits) (lib.attrValues templates)
          )
        );
      in
      lib.optional (bad != [ ]) (
        "agenix-extras: ignored restart/reload entries with unrecognized unit type: "
        + lib.concatStringsSep ", " bad
      );
  };
}
