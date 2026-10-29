# Tests the shell helpers both modules share (path expansion and the
# checks done before rendering and pruning) by running them in bash.
{ pkgs }:

let
  extras = import ../modules/lib.nix {
    inherit pkgs;
    inherit (pkgs) lib;
  };

  # Runs the checks (and pruning) for the given template paths in "$dir"
  # (configured as `''${W}/dir`), with agenix in `''${W}/agenix(.d)` and the
  # given secret paths; prints `resolvedAll` and what's left in "$dir".
  # Template paths are expanded unless `literalTemplates` (as on NixOS);
  # agenix's paths always are.
  checkPathsMode =
    literalTemplates: secretPaths: paths:
    pkgs.writeShellScript "check-paths" ''
      ${extras.captureEnvSnippet}
      PATH=${
        pkgs.lib.makeBinPath [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
        ]
      }
      failed=0
      ${extras.expandFunction}
      ${extras.resolveFunction}
      ${extras.resolveTemplatesSnippet {
        templatePaths = pkgs.writeText "paths" (pkgs.lib.concatLines paths);
        expandPaths = !literalTemplates;
        expandAgenixPaths = true;
        renderedDir = "\${W}/dir";
        agenixDirs = [
          "\${W}/agenix"
          "\${W}/agenix.d"
        ];
        inherit secretPaths;
      }}
      ${extras.pruneSnippet}
      echo "resolvedAll=$resolvedAll failed=$failed"
      find "$dir" -mindepth 1 | sort
    '';
  checkPathsWith = checkPathsMode false;
  checkPaths = checkPathsWith [ ];
in

pkgs.runCommand "agenix-extras-shell"
  {
    nativeBuildInputs = [ pkgs.bash ];
  }
  ''
    set -u

    check() {
      if [[ $2 != "$3" ]]; then
        echo "FAIL $1: expected '$3', got '$2'" >&2
        exit 1
      fi
    }

    export A=/a B="b c" TRICKY='${"$"}{A}' XDG_RUNTIME_DIR=/run/user/1000
    # Named like variables of the scripts and of `expand` itself.
    export name=/n rest=/r dest=/d
    unset UNSET || true
    ${extras.captureEnvSnippet}
    ${extras.expandFunction}
    # Set after capturing, like a script's own variables: must not be used.
    name=/script

    check environment-only "$(expand '$name$rest$dest')" /n/r/d

    check braced "$(expand '${"$"}{A}/x')" /a/x
    check bare "$(expand '$A/x')" /a/x
    check runtime-dir "$(expand '${"$"}{XDG_RUNTIME_DIR}/agenix/x')" /run/user/1000/agenix/x
    check spaces "$(expand '$B/x')" "b c/x"
    check values-not-rescanned "$(expand '$TRICKY')" '${"$"}{A}'
    check literal-dollar "$(expand '/x/$/$1/${"$"}{1}/$A')" '/x/$/$1/${"$"}{1}//a'
    check no-commands "$(expand '/x/$(touch pwned)/`touch pwned`')" '/x/$(touch pwned)/`touch pwned`'
    test ! -e pwned || { echo "FAIL: a command ran" >&2; exit 1; }
    if expand '/x/$UNSET/y' 2>/dev/null; then echo "FAIL: unset variable accepted" >&2; exit 1; fi
    if expand '/x/${"$"}{UNSET}' 2>/dev/null; then echo "FAIL: unset variable accepted" >&2; exit 1; fi

    # The same file through a variable and literally, or through a symlink:
    # nothing is rendered or removed.
    mkdir -p work/dir work/real && ln -s real work/link && touch work/dir/stale
    export dir=$PWD/work/dir W=$PWD/work
    if res=$(${
      checkPaths [
        "\${W}/dir/x"
        "$PWD/work/dir/x"
      ]
    } 2>&1); then echo "FAIL: duplicate via variable accepted" >&2; exit 1; fi
    [[ $res == *"several templates render to"* ]] || { echo "FAIL: $res" >&2; exit 1; }
    if ${
      checkPaths [
        "\${W}/real/y"
        "\${W}/link/y"
      ]
    } 2>/dev/null; then echo "FAIL: duplicate via symlink accepted" >&2; exit 1; fi
    test -e work/dir/stale || { echo "FAIL: pruned despite duplicates" >&2; exit 1; }

    # A path that can't be expanded: nothing is pruned, as its file must stay.
    res=$(${
      checkPaths [
        "\${UNSET}/x"
        "\${W}/dir/kept"
      ]
    } 2>/dev/null)
    check unresolved "$(head -1 <<< "$res")" "resolvedAll=0 failed=1"
    test -e work/dir/stale || { echo "FAIL: pruned with an unresolved path" >&2; exit 1; }

    # agenix's secrets directory (a symlink to the current generation) and its
    # mount point: a template as or in either renders and removes nothing.
    mkdir -p work/agenix.d/1 && ln -s agenix.d/1 work/agenix
    # The template path is `$p`, expanded from the (exported) environment.
    for p in "$W/agenix" "$W/agenix/x" "$W/agenix.d/1/x" "$PWD/work/agenix.d"; do
      export p
      if res=$(${checkPaths [ "$p" ]} 2>&1); then echo "FAIL: $p accepted" >&2; exit 1; fi
      [[ $res == *"agenix directory"* ]] || { echo "FAIL: $p: $res" >&2; exit 1; }
    done
    test -e work/dir/stale || { echo "FAIL: pruned despite an agenix path" >&2; exit 1; }

    # A template path through a symlink inside the directory (which pruning
    # would remove), whether it leads out of the directory or stays in it,
    # and also when the directory is entered through an alias: nothing is
    # rendered or removed.
    mkdir -p work/app work/dir/subdir
    ln -s ../app work/dir/link && ln -s subdir work/dir/inner && ln -s dir work/alias
    for p in "$W/dir/link/config" "$W/dir/inner/config" "$W/alias/inner/config"; do
      export p
      if res=$(${checkPaths [ "$p" ]} 2>&1); then
        echo "FAIL: $p, through a symlink in the directory, accepted" >&2; exit 1
      fi
      [[ $res == *"goes through a symlink"* ]] || { echo "FAIL: $p: $res" >&2; exit 1; }
    done
    test -L work/dir/link && test -L work/dir/inner || { echo "FAIL: symlink pruned" >&2; exit 1; }
    rm work/dir/link work/dir/inner && rmdir work/dir/subdir

    # A template where agenix puts a secret: nothing is rendered or removed.
    if res=$(${checkPathsWith [ "$W/token" ] [ "\${W}/token" ]} 2>&1); then
      echo "FAIL: template at a secret's path accepted" >&2; exit 1
    fi
    [[ $res == *"which is secret"* ]] || { echo "FAIL: $res" >&2; exit 1; }

    # A destination that is relative after expansion, or the directory itself
    # (here through the variable instead of as configured): refused.
    export REL=relative
    for p in '$REL/x' "$PWD/work/dir"; do
      export p
      if res=$(${checkPaths [ "$p" ]} 2>&1); then echo "FAIL: $p accepted" >&2; exit 1; fi
      [[ $res == *"not an absolute path"* || $res == *"the template directory itself"* ]] \
        || { echo "FAIL: $p: $res" >&2; exit 1; }
    done

    # An agenix directory that is the template directory: refused, as the
    # template directory would hide or prune agenix's files.
    ln -sfn dir work/agenix
    if res=$(${checkPaths [ "\${W}/dir/kept" ]} 2>&1); then
      echo "FAIL: agenix directory as the template directory accepted" >&2; exit 1
    fi
    [[ $res == *"agenix directory"*"or inside it"* ]] || { echo "FAIL: $res" >&2; exit 1; }
    ln -sfn agenix.d/1 work/agenix

    # A secret inside the directory, really or through a symlink in it (which
    # pruning would remove), also when the directory is entered through an
    # alias: nothing is rendered or removed (on NixOS, the ramfs would also
    # hide it).
    mkdir -p work/app && ln -s ../app work/dir/applink
    for s in "$W/dir/stale" "$W/dir/applink/token" "$W/alias/applink/token"; do
      export s
      if res=$(${checkPathsWith [ "$s" ] [ "\${W}/dir/kept" ]} 2>&1); then
        echo "FAIL: secret $s inside the directory accepted" >&2; exit 1
      fi
      [[ $res == *"secret"*"is in"* ]] || { echo "FAIL: $s: $res" >&2; exit 1; }
    done
    test -L work/dir/applink && test -e work/dir/stale || { echo "FAIL: pruned" >&2; exit 1; }
    rm work/dir/applink

    # Shell syntax in agenix's paths that `expand` doesn't understand (and
    # that agenix's shell would run): can't be checked, so nothing is
    # rendered or removed.
    ${pkgs.lib.concatMapStrings
      (s: ''
        if res=$(${checkPathsWith [ s ] [ "\${W}/dir/kept" ]} 2>&1); then
          echo "FAIL: uninterpretable secret path ${pkgs.lib.escapeShellArg s} accepted" >&2; exit 1
        fi
        [[ $res == *"cannot interpret"* ]] || { echo "FAIL: $res" >&2; exit 1; }
      '')
      [
        "\${W:-/x}/token"
        "\${W}/$(echo dir)/token"
        "\${W}/`echo dir`/token"
      ]
    }

    # A template replacing a symlink on the way to a secret (here one under
    # a mount point, so every generation): refused.
    mkdir -p work/real/agenix.d && ln -s real work/link
    if res=$(${checkPathsWith [ "\${W}/link/agenix.d/1/s" ] [ "\${W}/link" ]} 2>&1); then
      echo "FAIL: template replacing a symlink to a secret accepted" >&2; exit 1
    fi
    [[ $res == *"on the way to"* ]] || { echo "FAIL: $res" >&2; exit 1; }

    # On NixOS template paths are literal but agenix expands its own: a
    # secret at `$H/token` and a template at its expansion collide.
    export H=/nonexistent/h
    if res=$(${checkPathsMode true [ "$H/token" ] [ "/nonexistent/h/token" ]} 2>&1); then
      echo "FAIL: template at an expanded secret path accepted" >&2; exit 1
    fi
    [[ $res == *"which is secret"* ]] || { echo "FAIL: $res" >&2; exit 1; }

    # All resolved: stale files go, current ones stay.
    touch work/dir/kept
    res=$(${checkPaths [ "\${W}/dir/kept" ]})
    check pruned "$res" "[agenix-extras] removing stale $PWD/work/dir/stale
    resolvedAll=1 failed=0
    $PWD/work/dir/kept"

    touch $out
  ''
