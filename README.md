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

The rendered file ends up at `/run/agenix-extras/<name>` by default.
Substitution is done with `replace-secret` from nixpkgs: the *template* (with
opaque `<AGENIX:…:PLACEHOLDER>` markers, no plaintext) goes into the Nix store;
the plaintext is read from `/run/agenix/<secret-name>` at activation time and
written only to `/run/agenix-extras/<name>`.

`/run/agenix-extras` is a ramfs, like agenix's own `/run/agenix.d`, so
rendered plaintext is never swapped to disk. Each rendered file is replaced
atomically. If a template fails to render (say its secret didn't decrypt), its
previous file stays in place, the other templates are still rendered, and the
activation is reported as failed. Files in `/run/agenix-extras` that no longer
belong to a template are removed.

Templates are rendered by an activation script that runs after agenix has
decrypted and chowned its secrets. With `systemd.sysusers.enable` or
`services.userborn.enable`, agenix decrypts from systemd units instead, so
templates are rendered by `agenix-extras.service`, ordered after
`agenix-chown.service` and re-run whenever agenix re-decrypts.

> **Changed default.** Earlier versions rendered to `/run/agenix/rendered/`,
> inside agenix's generation directory. Configs that reference
> `config.age.templates.<name>.path` pick up the new location automatically;
> hard-coded paths need updating.

### Restart/reload on change

Both `age.secrets.<name>` and `age.templates.<name>` accept:

- `restartUnits` - units restarted by `switch-to-configuration`.
- `reloadUnits`  - units reloaded (or restarted if no reload is defined).

For each listed unit, agenix-extras writes the relevant store paths into a
drop-in, `/etc/systemd/system/<unit>.d/agenix-extras.conf`, as
`X-Restart-Triggers` / `X-Reload-Triggers`. These are the same keys NixOS's
own `restartTriggers` / `reloadTriggers` produce. For a secret that's the
`.age` file; for a template it's the template source plus every secret's
`.age` the template references. When any of those change between system
generations, `switch-to-configuration` restarts or reloads the unit as part
of `nixos-rebuild switch` - the same machinery nixpkgs services use for
config-file changes. No activation-time state file, no hash bookkeeping.

Because it is a drop-in, it works for any unit: one defined in NixOS, one
that only comes from a package in `systemd.packages`, or a template instance
such as `getty@tty1.service` (only that instance is restarted). Units with
`restartIfChanged = false` are not restarted.

One consequence: rekeying an `.age` file (re-encrypting to a new recipient
list, plaintext unchanged) is treated as a change because the ciphertext
hash differs. Affected units will restart on the next switch.

Entries must be full unit names with a type suffix (`nginx.service`, not
`nginx`); anything else fails evaluation.

## Tests

Three NixOS VM tests live under [`tests/`](./tests):

- **`templates`** - boots a VM with the example module
  ([`example/module.nix`](./example/module.nix)) and asserts the rendered file
  at `/run/agenix-extras/app.toml` contains the substituted secrets with the
  expected permissions. It then switches to a specialisation with a template
  that fails to render, and checks that activation still completed, the other
  template rendered, and the failed one kept its previous content. Switching
  back checks that the orphaned file is removed. The same module is what the
  example flake imports, so the example is the test fixture.
- **`restart-on-change`** - boots a VM with a secret whose `restartUnits` lists
  a NixOS-defined `demo.service`, a `pkgdemo.service` that only comes from
  `systemd.packages`, and the template instance `inst@a.service`. Switches to a
  specialisation whose `.age` file decrypts to different plaintext and asserts
  all three got a new PID while the unlisted `inst@b.service` did not. Then
  switches to one without `restartUnits` and checks that everything is still
  running.
- **`sysusers`** - same template checks with `services.userborn.enable`, where
  rendering happens in `agenix-extras.service`. The template is owned by a user
  that only exists once userborn has run, and switching to a changed secret
  must re-render it.

Run locally (needs `/dev/kvm`):

```sh
nix flake check                                # all tests
nix build .#checks.x86_64-linux.templates      # one at a time
nix build .#checks.x86_64-linux.restart-on-change
nix build .#checks.x86_64-linux.sysusers
```

Besides the VM tests, `checks` has two cheap ones: `formatting` (`nixfmt
--check` over the tree) and `example`, which evaluates
[`example/configuration.nix`](./example/configuration.nix).

GitHub Actions ([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) runs
an eval-only `nix flake check --no-build`, builds the cheap checks, and then
runs each VM test as its own job on `ubuntu-latest` (which has nested KVM).
The list of VM tests comes from the flake, so a new test only needs adding
to `checks`. A weekly workflow opens a PR that updates `flake.lock`.

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
  users are created (chain: `agenixInstall → users → agenixChown →
  agenix-extras`, or the equivalent systemd units under sysusers/userborn).
  Setting `owner` to any declared user works fine, but you cannot point
  `users.users.<n>.hashedPasswordFile` at a rendered template because users
  are created first and need the file to already exist.

- **`age.templates.<name>.path` must be in a root-only directory.** Rendering
  writes a temporary file next to `path` and renames it into place, so the
  final `mv` is atomic on the same filesystem. If the parent directory is
  writable by another user, that user could swap the temporary file between
  steps and trick root into writing the rendered secret elsewhere. The default
  `/run/agenix-extras/` is safe; if you point `path` at e.g.
  `/var/lib/<service>/`, make sure only root can write to that directory. Such
  paths are not on a ramfs and are not cleaned up when the template is removed.

- **`example/` is a demo, not a starting template.** The example imports
  fixture `.age` files under `tests/secrets/` encrypted to the checked-in
  test SSH key. On a real host with a different host key, decryption will
  fail. Copy the structure, but encrypt your own secrets to your host's
  public key.
