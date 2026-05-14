# Smoke-tests for the home-manager module.
#
# We don't boot a VM here: the heavy lifting (template-rendering shell, secret
# discovery, trigger plumbing) is shared with the NixOS module and exercised
# by tests/templates.nix and tests/restart-on-change.nix. This test verifies
# the home-manager wiring — that a home-manager config evaluates, produces an
# agenix-extras.service ordered after agenix.service, and attaches
# X-Restart-Triggers to user units that consume secrets/templates.
{
  pkgs,
  self,
  home-manager,
}:

let
  lib = pkgs.lib;

  fakeAge = builtins.toFile "fake-token.age" "encrypted-blob";

  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeManagerModules.default
      (
        { config, ... }:
        {
          home.username = "test";
          home.homeDirectory = "/home/test";
          home.stateVersion = "25.11";
          # nixpkgs follows `nixos-unstable` while HM here pins `release-25.11`;
          # silence the resulting version-mismatch nag.
          home.enableNixpkgsReleaseCheck = false;

          age.identityPaths = [ "/home/test/.ssh/id_ed25519" ];
          age.secrets.api-token = {
            file = fakeAge;
            restartUnits = [ "mbsync.service" ];
          };
          age.templates."app.toml".content = ''
            token = "${config.age.placeholder.api-token}"
          '';
        }
      )
    ];
    extraSpecialArgs = { };
  };

  cfg = hm.config;

  rendererService = cfg.systemd.user.services.agenix-extras or null;
  mbsyncTrigger =
    (cfg.systemd.user.services.mbsync.Service or { }).X-Restart-Triggers or null;
  renderScript = if rendererService == null then null else rendererService.Service.ExecStart;
in

pkgs.runCommand "agenix-extras-home-smoke"
  {
    inherit renderScript mbsyncTrigger;
    rendererServiceJson = builtins.toJSON rendererService;
  }
  ''
    set -eu

    # 1. The rendering oneshot exists and waits on agenix.
    if [ -z "$renderScript" ]; then
      echo "FAIL: systemd.user.services.agenix-extras is missing" >&2
      exit 1
    fi

    case "$rendererServiceJson" in
      *'"After":["agenix.service"]'*) : ;;
      *) echo "FAIL: agenix-extras unit does not order After=agenix.service" >&2
         echo "got: $rendererServiceJson" >&2
         exit 1 ;;
    esac

    # 2. The generated render script contains the runtime shell expansion
    #    (HM paths) rather than a single-quoted literal — and references the
    #    secret's runtime path.
    head -20 "$renderScript"
    grep -q '"''${XDG_RUNTIME_DIR}/agenix/rendered"' "$renderScript" \
      || { echo "FAIL: render script does not use XDG_RUNTIME_DIR" >&2; exit 1; }
    grep -q replace-secret "$renderScript" \
      || { echo "FAIL: render script does not call replace-secret" >&2; exit 1; }

    # 3. mbsync.service got an X-Restart-Triggers entry pointing at the fake
    #    .age store path.
    if [ -z "$mbsyncTrigger" ]; then
      echo "FAIL: mbsync.service has no X-Restart-Triggers" >&2
      exit 1
    fi
    grep -q '${fakeAge}' "$mbsyncTrigger" \
      || { echo "FAIL: mbsync trigger does not reference the .age store path" >&2;
           cat "$mbsyncTrigger" >&2; exit 1; }

    echo "OK"
    touch "$out"
  ''
