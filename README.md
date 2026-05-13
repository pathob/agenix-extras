# agenix-extras

A thin NixOS module that layers two [sops-nix][sops-nix] features on top of
[agenix][agenix]:

1. **Templates** - render config files with secret placeholders substituted at
   activation time, so plaintext secrets never enter the Nix store.

2. **Restart/reload on change** - declaratively bounce systemd units when a
   secret or template content changes between activations.

## Why

[agenix][agenix] and [sops-nix][sops-nix] are the two mainstream NixOS secret
managers. agenix is small, uses SSH keys directly, and stores one secret per
encrypted file. sops-nix is larger, wraps Mozilla's `sops`, supports more key
backends and file formats, and ships several useful features agenix doesn't -
notably templates and unit reload-on-change. This module brings those two
features to agenix users who prefer the simpler one-secret-per-file model.

agenix is consumed as a flake input here, unmodified - downstream projects
point `inputs.agenix-extras.inputs.agenix.follows` at their own agenix pin.
Restart/reload is wired through NixOS's standard `restartTriggers` /
`reloadTriggers` on the named units, so `switch-to-configuration` handles
change detection at eval time with no runtime state.

[agenix]: https://github.com/ryantm/agenix
[sops-nix]: https://github.com/Mic92/sops-nix

> **AI-generated.** This project was initially written by Claude Opus 4.7
> (Anthropic). It is exercised by two NixOS VM tests (see [Tests](#tests))
> covering both features, but is not yet mature - treat it as a starting
> point, not a vetted dependency.

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix.url = "github:ryantm/agenix";
    agenix-extras.url = "github:you/agenix-extras";
    agenix-extras.inputs.agenix.follows = "agenix";
    agenix-extras.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, agenix-extras, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        agenix-extras.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

A complete working example lives in [`example/`](./example).

### Templates

```nix
{ config, pkgs, ... }: {
  age.secrets.api-token.file = ./secrets/api-token.age;

  age.templates."app.toml" = {
    owner = "myapp";
    content = ''
      token = "${config.age.placeholder.api-token}"
    '';
    reloadUnits = [ "myapp.service" ];
  };

  systemd.services.myapp.serviceConfig.ExecStart =
    "${pkgs.myapp}/bin/myapp --config ${config.age.templates."app.toml".path}";
}
```

The rendered file ends up at `/run/agenix/rendered/<name>` by default.
Substitution is done with `replace-secret` from nixpkgs: the *template* (with
opaque `<AGENIX:…:PLACEHOLDER>` markers, no plaintext) goes into the Nix store;
the plaintext is read from `/run/agenix/<secret-name>` at activation time and
written only to `/run/agenix/rendered/<name>`.

### Restart/reload on change

Both `age.secrets.<name>` and `age.templates.<name>` accept:

- `restartUnits` - units restarted by `switch-to-configuration`.
- `reloadUnits`  - units reloaded (or restarted if no reload is defined).

For each listed unit, agenix-extras adds the relevant store paths to the
unit's `restartTriggers` / `reloadTriggers` at eval time. For a secret that's
the `.age` file; for a template it's the template source plus every secret's
`.age` the template references. When any of those change between system
generations, `switch-to-configuration` restarts or reloads the unit as part
of `nixos-rebuild switch` - the same machinery nixpkgs services use for
config-file changes. No activation-time state file, no hash bookkeeping.

One consequence: rekeying an `.age` file (re-encrypting to a new recipient
list, plaintext unchanged) is treated as a change because the ciphertext
hash differs. Affected units will restart on the next switch.

Supported unit kinds: `service`, `socket`, `timer`, `path`, `target`,
`mount`, `automount`, `slice`. Other suffixes are ignored with a warning.

## Tests

Two NixOS VM tests live under [`tests/`](./tests):

- **`templates`** - boots a VM with the example module
  ([`example/module.nix`](./example/module.nix)) and asserts the rendered file
  at `/run/agenix/rendered/app.toml` contains the substituted secrets with the
  expected permissions. The same module is what the example flake imports, so
  the example is the test fixture.
- **`restart-on-change`** - boots a VM with a long-running `demo.service` and a
  secret that has `restartUnits = [ "demo.service" ]`. Switches to a
  specialisation whose `.age` file decrypts to different plaintext and asserts
  the service got a new PID.

Run locally (needs `/dev/kvm`):

```sh
nix flake check                                # both tests
nix build .#checks.x86_64-linux.templates      # one at a time
nix build .#checks.x86_64-linux.restart-on-change
```

GitHub Actions ([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) runs
two jobs: an eval-only `nix flake check --no-build`, and a matrix job that
builds each VM test on `ubuntu-latest` (which has nested KVM).

The fixtures under `tests/keys/` and `tests/secrets/` are **test-only**: the
private SSH key is checked in so the test can decrypt the pre-encrypted `.age`
files. Never reuse them.

## Limitations

- **Linux only.** agenix supports Darwin via launchd, but the post-activation
  hook this module installs is wired as a NixOS activation script. Porting to
  launchd would mean reshaping `system.activationScripts.agenix-extras` into a
  daemon ordered after `activate-agenix`.

- **No home-manager module.** Only the NixOS module is provided.

- **Templates cannot supply `hashedPasswordFile`.** Templates render *after*
  the `users` activation snippet (chain: `agenixInstall → users → agenixChown
  → agenix-extras`). Setting `owner` to any declared user works fine, but you
  cannot point `users.users.<n>.hashedPasswordFile` at a rendered template
  because `users` runs first and needs the file to already exist.

- **`age.templates.<name>.path` must be in a root-only directory.** Rendering
  uses a sibling `${path}.tmp` to keep the final `mv` atomic on the same
  filesystem. If the parent directory is writable by another user, that user
  could race a symlink at the tmp path and trick root into writing the
  rendered secret elsewhere. The default `/run/agenix/rendered/` is safe; if
  you point `path` at e.g. `/var/lib/<service>/`, make sure only root can
  write to that directory.

- **`example/` is a demo, not a starting template.** The example imports
  fixture `.age` files under `tests/secrets/` encrypted to the checked-in
  test SSH key. On a real host with a different host key, decryption will
  fail. Copy the structure, but encrypt your own secrets to your host's
  public key.
