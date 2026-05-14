# Shared helpers used by both the NixOS module (modules/agenix-extras.nix)
# and the home-manager module (modules/agenix-extras-home.nix).
#
# Everything here is pure data/string construction. The thin wrappers that
# follow plug these helpers into the right activation hook and the right
# systemd subtree for each context.
{
  lib,
  pkgs,
  cfg,
}:

let
  inherit (cfg) secrets templates;

  placeholderFor = name: "<AGENIX:${builtins.hashString "sha256" name}:PLACEHOLDER>";

  # Plain text of a template, for placeholder discovery at eval time.
  templateText = tpl: if tpl.file != null then builtins.readFile tpl.file else tpl.content;

  templateSource =
    tpl:
    if tpl.file != null then
      tpl.file
    else
      pkgs.writeText "agenix-template-${lib.strings.sanitizeDerivationName tpl.name}" tpl.content;

  # Store paths whose change should trigger units that depend on this
  # template: the template source itself, plus every `.age` it references.
  templateTriggers =
    tpl:
    [ (templateSource tpl) ]
    ++ map (n: secrets.${n}.file) (
      lib.filter (n: lib.hasInfix (placeholderFor n) (templateText tpl)) (lib.attrNames secrets)
    );

  defaultRenderedDir = "${cfg.secretsDir}/rendered";

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
          default = "${defaultRenderedDir}/${config.name}";
          defaultText = lib.literalExpression ''"''${cfg.secretsDir}/rendered/''${config.name}"'';
          description = "Path where the rendered file is written.";
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
          description = "Units restarted when this template changes.";
        };

        reloadUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "nginx.service" ];
          description = "Units reloaded (or restarted) when this template changes.";
        };
      };
    }
  );

  # When `pathsExpand` is true, paths sourced from agenix (`cfg.secretsDir`
  # etc.) may legitimately contain shell variables like `${XDG_RUNTIME_DIR}`
  # that we want the shell to expand at runtime. To do that safely we emit a
  # header that captures the trusted prefix into shell variables once, and
  # the rest of the script refers to those variables — so user-supplied path
  # values can still be `escapeShellArg`-quoted and any `$()`, backticks or
  # quote characters in them are inert.
  #
  # `_AE_SECRETS` and `_AE_RENDERED` are the captured prefixes; anything
  # under them ends up as `"$_AE_RENDERED/<escaped-suffix>"`.
  #
  # `rewritePath`: if the value starts with one of the known agenix prefixes,
  # split it and emit `"$VAR<escaped-suffix>"`. Otherwise (user override,
  # known absolute literal), `escapeShellArg` the whole thing.
  rewritePath =
    pathsExpand: value:
    if !pathsExpand then
      lib.escapeShellArg value
    else
      let
        renderedPrefix = "${cfg.secretsDir}/rendered";
        secretsPrefix = cfg.secretsDir;
      in
      if lib.hasPrefix "${renderedPrefix}/" value then
        ''"$_AE_RENDERED"${lib.escapeShellArg (lib.removePrefix renderedPrefix value)}''
      else if value == renderedPrefix then
        ''"$_AE_RENDERED"''
      else if lib.hasPrefix "${secretsPrefix}/" value then
        ''"$_AE_SECRETS"${lib.escapeShellArg (lib.removePrefix secretsPrefix value)}''
      else if value == secretsPrefix then
        ''"$_AE_SECRETS"''
      else
        # Not under any known prefix. Must be a literal absolute path
        # (commonAssertions enforces this).
        lib.escapeShellArg value;

  renderTemplate =
    { chmodOwner ? true, pathsExpand ? false }:
    tpl:
    let
      referenced = lib.filter (n: lib.hasInfix (placeholderFor n) (templateText tpl)) (
        lib.attrNames secrets
      );
      tplPath = rewritePath pathsExpand tpl.path;
      tplPathTmp = rewritePath pathsExpand "${tpl.path}.tmp";
      src = lib.escapeShellArg (templateSource tpl);
      installOwner =
        if chmodOwner then "install -m 0600 -o root -g root /dev/null" else "install -m 0600 /dev/null";
    in
    ''
      printf '[agenix-extras] rendering %s -> %s\n' ${lib.escapeShellArg tpl.name} ${tplPath}
      mkdir -p "$(dirname ${tplPath})"
      ${installOwner} ${tplPathTmp}
      cat ${src} > ${tplPathTmp}
      ${lib.concatMapStringsSep "\n" (n: ''
        ${pkgs.replace-secret}/bin/replace-secret \
          ${lib.escapeShellArg (placeholderFor n)} \
          ${rewritePath pathsExpand secrets.${n}.path} \
          ${tplPathTmp}
      '') referenced}
      chmod ${lib.escapeShellArg tpl.mode} ${tplPathTmp}
      ${lib.optionalString chmodOwner ''
        chown ${lib.escapeShellArg tpl.owner}:${lib.escapeShellArg tpl.group} ${tplPathTmp}
      ''}
      mv -f ${tplPathTmp} ${tplPath}
    '';

  activationScriptText =
    { chmodOwner, pathsExpand ? false }:
    let
      # System: 0751 so non-root services can traverse the directory and
      # open() the files inside (the rendered files are themselves mode-
      # restricted per-template). HM: 0700, the dir already lives under
      # $XDG_RUNTIME_DIR/ which is per-user.
      installDir =
        if chmodOwner then "install -d -m 0751 -o root -g root" else "install -d -m 0700";
      # Header that captures the agenix-provided runtime paths into shell
      # variables. Only emitted in pathsExpand mode (HM); on NixOS the values
      # are literal absolute paths and we just escapeShellArg them inline.
      header = lib.optionalString pathsExpand ''
        _AE_SECRETS="${cfg.secretsDir}"
        _AE_RENDERED="${defaultRenderedDir}"
      '';
      renderedDirArg = rewritePath pathsExpand defaultRenderedDir;
    in
    ''
      set -euo pipefail
      ${header}${installDir} ${renderedDirArg}
      ${lib.concatMapStringsSep "\n" (renderTemplate { inherit chmodOwner pathsExpand; }) (
        lib.attrValues templates
      )}
    '';

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

  unitSubtree =
    unit:
    let
      kind = unitKind unit;
    in
    if kind == null then null else kindToAttr.${kind} or null;

  # `{ services.<n>.${triggersField} = [...]; sockets.<n>... }` for the
  # given option field (`restartUnits` or `reloadUnits`).
  triggersFor =
    field: triggersField:
    let
      entries =
        lib.concatMap (
          s: map (u: { inherit u; triggers = [ s.file ]; }) (s.${field} or [ ])
        ) (lib.attrValues secrets)
        ++ lib.concatMap (
          t: map (u: { inherit u; triggers = templateTriggers t; }) t.${field}
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
      lib.mapAttrs (
        _: unit:
        unit // { ${triggersField} = lib.unique unit.${triggersField}; }
      ) kindAttrs
    ) grouped;

  badUnits = lib.filter (u: unitSubtree u == null) (
    lib.unique (
      lib.concatMap (s: (s.restartUnits or [ ]) ++ (s.reloadUnits or [ ])) (lib.attrValues secrets)
      ++ lib.concatMap (t: t.restartUnits ++ t.reloadUnits) (lib.attrValues templates)
    )
  );

  commonAssertions =
    lib.mapAttrsToList (name: t: {
      assertion = !(t.file != null && t.content != "");
      message = "age.templates.${name}: set either `file` or `content`, not both.";
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

  # Path-shape rules differ between the modules:
  # - NixOS: must be a literal absolute path. No `$VAR` allowed because the
  #   activation script treats `tpl.path` as a literal (escapeShellArg'd).
  # - HM: may be a literal absolute path, OR start with `${cfg.secretsDir}`
  #   (the agenix-provided runtime-expanded prefix). User-overridden HM
  #   paths must still be literal — we don't expand arbitrary shell vars.
  pathAssertions =
    { pathsExpand }:
    lib.mapAttrsToList (
      name: t:
      let
        ok =
          lib.hasPrefix "/" t.path
          || (pathsExpand && lib.hasPrefix "${cfg.secretsDir}/" t.path)
          || (pathsExpand && t.path == cfg.secretsDir);
        hint = lib.optionalString pathsExpand
          " (or start with `\${cfg.secretsDir}` = ${cfg.secretsDir})";
      in
      {
        assertion = ok;
        message = "age.templates.${name}.path must be an absolute path${hint}; got: ${t.path}";
      }
    ) templates;

  commonWarnings = lib.optional (badUnits != [ ]) (
    "agenix-extras: ignored restart/reload entries with unrecognized unit type: "
    + lib.concatStringsSep ", " badUnits
  );
in

{
  inherit
    pathAssertions
    placeholderFor
    templateType
    templateTriggers
    renderTemplate
    activationScriptText
    triggersFor
    unitSubtree
    unitKind
    unitName
    kindToAttr
    defaultRenderedDir
    commonAssertions
    commonWarnings
    ;
}
