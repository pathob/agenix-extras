# Test fixtures - DO NOT USE IN PRODUCTION

This directory contains an SSH ed25519 keypair used **only** by the NixOS VM
tests under `tests/`. The private key is intentionally checked in so the tests
can decrypt the pre-encrypted `.age` files in `tests/secrets/`.

Anyone with access to this repository can read these "secrets". Never reuse
this key for anything real.
