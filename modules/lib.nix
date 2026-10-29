# Code shared by the NixOS module (agenix-extras.nix) and the home-manager
# module (agenix-extras-home.nix): template options, placeholder and trigger
# bookkeeping, the per-template renderer, and the assertions.
{
  lib,
  pkgs,
}:

rec {
  placeholderFor = name: "<AGENIX:${builtins.hashString "sha256" name}:PLACEHOLDER>";

  # Copy a Nix path into the store, as NixOS's own restartTriggers do. Plain
  # `toString` keeps a path outside the store (e.g. `/etc/nixos/x.age` in a
  # non-flake config) as-is, so editing the file wouldn't change the trigger.
  toStorePath = x: if lib.isPath x then "${x}" else x;

  # `foo.service`, `foo@bar.service`, `foo@.service`, ...
  isUnitName =
    u:
    builtins.match "[^/]+\\.(service|socket|device|mount|automount|swap|target|path|timer|slice|scope)" u
    != null;
  isInstanceName = u: builtins.match "[^/]*@[^/]+\\.[a-z]+" u != null;

  placeholderOption = lib.mkOption {
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

  # `restartUnits` / `reloadUnits`, for secrets and templates. `units` says
  # which units can be named, `switch` what applies the change.
  unitListOptions =
    {
      units,
      switch,
      example,
      changes,
    }:
    {
      restartUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        inherit example;
        description = "${units} restarted by ${switch} when ${changes} changes.";
      };
      reloadUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        inherit example;
        description = "${units} reloaded (or restarted if no reload is defined) by ${switch} when ${changes} changes.";
      };
    };

  # Options of `age.templates.<name>` that both modules share. The submodule's
  # `name` and `config` are passed through.
  templateOptions =
    {
      name,
      config,
      renderedDir,
      unitOptions,
    }:
    {
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
        # Octal (`0440`, also with leading zeros or an operator like `=0440`) or
        # symbolic (`u=r,g=r`): the forms chmod accepts.
        type =
          let
            clause = "[ugoa]*([-+=]([rwxXst]*|[ugo]))+";
          in
          lib.types.strMatching "[-+=]?0*[0-7]{1,4}|${clause}(,${clause})*"
          // {
            description = "chmod mode (octal like `0440` or symbolic like `u=r,g=r`)";
          };
        default = "0400";
        description = "Permissions of the rendered file, in a form chmod accepts (octal or symbolic).";
      };
    }
    // unitOptions;

  # Helpers that depend on the module's `age` config.
  forConfig = cfg: rec {
    inherit (cfg) secrets templates;

    # The store path Nix evaluation should track for `restartTriggers` /
    # `reloadTriggers`. For agenix secrets that's the encrypted `.age` file
    # (the plaintext only exists at runtime, but its inputs are the
    # ciphertext + identity, and the identity is fixed per host so the
    # ciphertext is what changes). For templates it's the source file plus
    # every referenced secret's `.age`, because a template's output depends
    # on both.
    secretTrigger = name: toStorePath secrets.${name}.file;
    templateTriggers = tpl: [ (templateSource tpl) ] ++ map secretTrigger (referencedSecrets tpl);

    # Plain text of a template, for placeholder discovery at eval time.
    # Setting neither `file` nor `content` fails an assertion, but the
    # assertions themselves scan the text, so that case reads as empty here.
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

    # For every unit named in a `restartUnits` / `reloadUnits` option, the
    # store paths whose change should restart / reload it.
    unitTriggers =
      field:
      lib.zipAttrsWith (_: vs: lib.unique (lib.concatLists vs)) (
        lib.concatMap (s: map (u: { ${u} = [ (toStorePath s.file) ]; }) s.${field}) (lib.attrValues secrets)
        ++ lib.concatMap (t: map (u: { ${u} = templateTriggers t; }) t.${field}) (lib.attrValues templates)
      );
    restartTriggers = unitTriggers "restartUnits";
    reloadTriggers = unitTriggers "reloadUnits";
    triggeredUnits = lib.unique (lib.attrNames restartTriggers ++ lib.attrNames reloadTriggers);

    # The `[Unit]` drop-in that attaches a unit's triggers, plus `extra`
    # lines.
    dropInText = u: extra: ''
      [Unit]
      ${lib.optionalString (restartTriggers ? ${u}) "X-Restart-Triggers=${toString restartTriggers.${u}}"}
      ${lib.optionalString (reloadTriggers ? ${u}) "X-Reload-Triggers=${toString reloadTriggers.${u}}"}
      ${extra}
    '';

    # Every template's path, one per line, for pruning stale files.
    templatePaths = pkgs.writeText "agenix-extras-paths" (
      lib.concatLines (lib.mapAttrsToList (_: t: t.path) templates)
    );

    # Arguments for `renderOne`, without the owner and group.
    renderArgs =
      tpl:
      [
        tpl.name
        (templateSource tpl)
        tpl.path
        tpl.mode
      ]
      ++ lib.concatMap (n: [
        (placeholderFor n)
        secrets.${n}.path
      ]) (referencedSecrets tpl);

    # Assertions both modules make. `isAbsolute` says whether a template
    # path is absolute; `renderedDir` is the default directory.
    assertions =
      { isAbsolute, renderedDir }:
      lib.mapAttrsToList (name: t: {
        assertion = (t.file == null) != (t.content == null);
        message = "age.templates.${name}: set exactly one of `file` and `content`.";
      }) templates
      # Normalised, so the duplicate-path check below, which compares paths
      # verbatim, also catches e.g. `/run/agenix-extras/./x` vs `.../x`.
      ++ lib.mapAttrsToList (name: t: {
        assertion =
          isAbsolute t.path && builtins.match ".*(//|/\\./|/\\.\\./).*|.*/(\\.|\\.\\.)?" t.path == null;
        message = "age.templates.${name}.path must be an absolute path without `.`, `..` or empty components; got: ${t.path}";
      }) templates
      ++ lib.mapAttrsToList (name: t: {
        assertion = t.path != renderedDir;
        message = "age.templates.${name}.path is the directory templates are rendered into; use a file in it, e.g. ${renderedDir}/${name}.";
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
            # Name the secret's own flag first: agenix's `age.enable`
            # defaults to "any secret enabled", so it is a consequence, not
            # the cause.
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
  };

  # Shell snippet saving the exported environment, as the script was started
  # with it, in the associative array `agenixExtrasEnv`. Must come before the
  # script sets any variable, so that `expand` can't pick up one of those
  # (or its own) instead of the caller's.
  # (`compgen -e` isn't available in nixpkgs' non-interactive bash.)
  captureEnvSnippet = ''
    declare -A agenixExtrasEnv=()
    while IFS= read -r -d "" agenixExtrasVar; do
      agenixExtrasEnv[''${agenixExtrasVar%%=*}]=''${agenixExtrasVar#*=}
    done < <(${pkgs.coreutils}/bin/env -0)
    unset agenixExtrasVar
  '';

  # Shell function `expand PATH`: replace every `${VAR}` and `$VAR` in PATH
  # with the variable's value (agenix's own paths use both), failing if one
  # is unset. Any other `$` is kept as is. Nothing is evaluated, so a path
  # can't run commands, and values aren't scanned again.
  # Variables are looked up in the environment the script was started with
  # (see `captureEnvSnippet`), never in the script's own variables.
  expandFunction = ''
    expand() {
      local rest=$1 out="" n
      local re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))?(.*)$'
      while [[ $rest == *'$'* && $rest =~ $re ]]; do
        out+=''${BASH_REMATCH[1]}
        n=''${BASH_REMATCH[3]:-''${BASH_REMATCH[4]}}
        if [[ -z $n ]]; then
          out+='$'
        elif [[ -v agenixExtrasEnv[$n] ]]; then
          out+=''${agenixExtrasEnv[$n]}
        else
          printf '[agenix-extras] %s is not set (in %s)\n' "$n" "$1" >&2
          return 1
        fi
        rest=''${BASH_REMATCH[5]}
      done
      printf '%s\n' "$out$rest"
    }
  '';

  # Shell function `resolve PATH`: where a file written to PATH actually
  # ends up. Symlinks in the parent directories are followed, but not a
  # symlink at PATH itself, which the renderer replaces rather than writes
  # through.
  resolveFunction = ''
    resolve() {
      local parent
      parent=$(realpath -m -- "$(dirname -- "$1")") || return 1
      printf '%s/%s\n' "''${parent%/}" "$(basename -- "$1")"
    }
  '';

  # Shell snippet removing files in "$dir" that no longer belong to a
  # template, given every template's path (resolved with `resolve`, after
  # `expand` if `expandPaths`). Runs before rendering, so a stale file or
  # directory can't be in the way when a template's path turns into a
  # directory or vice versa.
  pruneSnippet =
    { templatePaths, expandPaths }:
    ''
      expected=$(while IFS= read -r p; do
        ${lib.optionalString expandPaths ''p=$(expand "$p") || continue''}
        resolve "$p"
      done < ${templatePaths})
      while IFS= read -r -d "" f; do
        if ! grep -Fxq -- "$f" <<< "$expected"; then
          printf '[agenix-extras] removing stale %s\n' "$f"
          rm -f -- "$f"
        fi
      done < <(find "$dir" -mindepth 1 ! -type d -print0)
      find "$dir" -mindepth 1 -depth -type d -empty -delete
    '';

  # Render one template: substitute every placeholder its source references
  # with the contents of the corresponding decrypted secret file, then move
  # the result into place.
  #
  # Usage: render-one NAME SRC DEST MODE [OWNER GROUP] [PLACEHOLDER SECRET-PATH]...
  #
  # OWNER and GROUP are only taken with `chown`. Paths are taken as they are:
  # where they need expanding, the caller does that, from the same environment
  # its checks used.
  #
  # This is a separate process rather than inline shell so that `set -e` is
  # scoped to a single template: bash ignores `set -e` inside anything on the
  # left of `||`, subshells included, and setting it in an activation script
  # would leak into every snippet that runs after it.
  mkRenderOne =
    { chown }:
    pkgs.writeShellScript "agenix-extras-render-one" ''
      set -euo pipefail
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.replace-secret
        ]
      }
      name=$1 src=$2 dest=$3 mode=$4
      shift 4
      ${lib.optionalString chown ''
        owner=$1 group=$2
        shift 2
      ''}

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
      chmod -- "$mode" "$tmp"
      ${lib.optionalString chown ''chown "$owner:$group" "$tmp"''}
      # -T: fail if `dest` is a directory instead of moving the file into it.
      mv -fT "$tmp" "$dest"
      trap - EXIT
    '';
}
