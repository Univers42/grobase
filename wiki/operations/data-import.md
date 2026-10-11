# Data import — move a seed set into a grobase data center

A **seed set** is what `scripts/ops/vault-seed.sh` captures: one dump per engine plus a
`MANIFEST.json` (v2) naming each dump and its sha256. An **import** carries that set into
another grobase (a VM, a LAN box) and replays it there without touching anything the dumps
do not carry.

| Step | Command (run from the repo root) | What it changes | Gate |
| --- | --- | --- | --- |
| pack | `scripts/ops/grobase-import.sh pack SEED_DIR [--id ID]` | writes `<IMPORT_ROOT>/<id>/` (only the dumps the manifest names, `packets.sha256`, `state/<packet>`) | m222 |
| push | `scripts/ops/grobase-import.sh push ID --dest HOST:/var/lib/grobase-import` | rsyncs the import dir to the target, re-verifies it there | m223 |
| rebind | `scripts/ops/grobase-import-rebind.sh ID NEW_ID --target-ssh HOST` | derives `NEW_ID` whose `tenant_databases` DSNs are re-sealed for the target's engines and key | `internal/mountrebind` tests |
| apply | `scripts/ops/grobase-import.sh apply ID --confirm` (on the target) | stops the running `mini-baas` compose set, snapshots its volumes, restores every packet, checks postgres row counts, runs `db-bootstrap` + `pg-migrate`, restarts exactly the set it stopped | m224 · m225 · m226 |
| rollback | `scripts/ops/grobase-import.sh rollback ID --confirm` (on the target) | puts the volumes back from apply's snapshot and restarts the recorded set | m226 |

`IMPORT_ROOT` defaults to `$XDG_STATE_HOME/grobase/import`; on a data center use a
directory on its data disk (`/var/lib/grobase-import` on the b2b VM), never `/tmp`.

Exit codes, every verb: `0` done · `1` a step failed · `2` refused before any change ·
`3` (apply) restored, but postgres row counts differ — `apply/counts.diff` names the tables.

## Apply, in order

1. Every packet re-checksummed; an earlier apply of the same id that did not finish is
   refused (`rollback` first, or `--force`).
2. The running set (`docker ps` filtered on `com.docker.compose.project=mini-baas`, minus
   `--rm` containers) is recorded in `apply/running.before`, then stopped.
3. Each volume of that set is tarred cold into `apply/volumes/` with `SHA256SUMS`; the entry
   count of every tar must equal the volume's, an empty volume included.
4. The engines start; each packet is restored by `vault-restore.sh` with
   `SKIP_STACK_CYCLE=1 ENGINES=<one> KEEP_RUNNING=<the others>`, so nothing else runs while
   it replays (`apply/restore.log`).
5. `pg-counts.sh check` compares every table the dump carried with the live count
   (`apply/counts.log`).
6. `mini-baas-db-bootstrap` then `mini-baas-pg-migrate` run (`apply/migrate.log`), and the
   recorded set starts again (`apply/running.after`).

If a step fails before the first restore, the trap restarts the recorded set and nothing
changed. If it fails during restores, the stack stays down and the message names the
`rollback` command.

Real run, b2b VM, 2026-10-11 (import `seeds-20261011T014534Z-b2b`):

```text
[grobase-import] every packet verified_checksum
[grobase-import] stopping 35 mini-baas containers
[grobase-import] restoring postgres (log: /var/lib/grobase-import/seeds-20261011T014534Z-b2b/apply/restore.log)
[grobase-import] restoring mysql (log: …)
[grobase-import] restoring mongo (log: …)
[grobase-import] restoring minio (log: …)
[grobase-import] restoring redis (log: …)
[grobase-import] restoring mssql (log: …)
[grobase-import] running mini-baas-db-bootstrap
[grobase-import] running mini-baas-pg-migrate
[grobase-import] applied seeds-20261011T014534Z-b2b; counts rc=0
```

## What it does not do

- **Counts, not values.** `pg-counts.sh` proves each table holds as many rows as the dump
  carried; a changed value under an unchanged count passes. Tables the dump did not carry
  are not looked at. MySQL, Mongo, MinIO, Redis and MSSQL are checked by their restore
  step only.
- **Mount rows the source key cannot open stay as they are.** `rebind` reports each row's
  outcome in the derived manifest; a row sealed under a key the source `.env` no longer
  holds is carried unchanged and will not open on the target.
- **No partial apply.** Every packet in the import is restored; drop a packet by packing
  a seed set without it.
- **The stack is down for the whole apply.** Do not leave it stopped across the VM's
  nightly `b2b-var-gc` (00:07), which prunes stopped containers older than 24 h.
