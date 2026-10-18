# A `[prod]` vault42 target for grobase

Declined 2026-10-18.

## Why

The prod tree was pushed from a capture stage on sgoinfre that holds `secrets/` only, not from
a checkout. `vault42 push` replaces the vault's tree with the target's root, so a `[prod]`
target rooted at this checkout would swap that tree for different files. `make vault42-*`
therefore knows `dev` only; `TARGET=prod` is refused by the CLI as an unknown target.

## Reopen when

- a prod root has been measured: its file list matches what the vault holds (`vault42 diff` empty), and
- the VM has its own vault42 identity, granted only grobase envs.

See [ADR 0001](../docs/adr/0001-vault42-cli-wiring.md).
