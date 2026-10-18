# 0001 — Wire the shared vault42 CLI into make, dev only

Status: accepted (2026-10-18). First ADR in this repo.

## Decision

- `vendor/scripts` is a git submodule of `https://github.com/Univers42/scripts.git` (branch
  `main`, pinned `cc0d2525`). HTTPS, because CI and the VM have no SSH key and the repo is
  public. Only its line was removed from the `.gitignore` "Accidental gitlinks" block.
- `vault42.conf` at the root has ONE target, `[dev]` (org `univers42`, project `grobase`).
- `orchestrators/makes/65-vault42.mk` adds `vault42-*` targets that only call
  `vendor/scripts/vault42/vault42.sh --config vault42.conf`.

## Conditions (devil D2–D9)

| | condition | where it holds |
|---|---|---|
| D2 | no prod target | `vault42.conf`; `make vault42-diff TARGET=prod` exits 2 (unknown target). [Why](../../.out-of-scope/grobase-vault42-prod-target.md) |
| D3 | first `vault42-push TARGET=dev` is the operator's, after `vault42-diff` and the C18 drill (push to a throwaway env, `pull --apply` into an empty dir, `diff -r`): dev was pushed from a stage of 15 files, not from this checkout | help of `vault42-push` |
| D4 | `TARGET`, `APPLY`, `YES` count only on the make command line (`$(origin)`) | `65-vault42.mk` |
| D5 | `85-fly.mk`, `60-secrets.mk`, `scripts/vault/ctl-env.sh` untouched | this branch |
| D6 | `GIT_SSH_COMMAND=false git clone --recurse-submodules` succeeds with the pin | submodule over HTTPS |
| D7 | other make recipes unchanged | `make -pq` database diff vs the base |
| D8 | no `ctl-remote` / `Makefile.bak` reference | `git grep` |
| D9 | missing `vendor/scripts` stops with `git submodule update --init vendor/scripts`; `make help` does not need it | `_V42_REQ` runs inside recipes only |

## Org

`vault42.conf` names `univers42`, the org the grobase project was created in on 2026-10-18.
`scripts/vault/ctl-env.sh` keeps its `univers-42` default; it answered 404 for the operator
on 2026-10-18. Reconciling the two is the operator's call, so that script is not edited here.

## Not deleted: fly and Vault targets

`CLAUDE.md` (:585) keeps `deploy/fly/` and `85-fly.mk` as the way back from the retired fly.io
deployment; (:457) keeps the HashiCorp Vault plane dormant, not deleted. Neither is touched.

## VM

No docker0: export `VAULT42_DOCKER_NETWORK=host`. The VM needs its own 42ctl identity, granted
only grobase envs (operator decision); vault42 copies no keystore.
