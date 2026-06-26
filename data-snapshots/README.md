# Demo-data snapshots (all engines)

Portable, compressed dumps of **every grobase data-plane engine**, so anyone can
clone the project, bring the stack up, and **restore a full demo dataset instead
of generating it from scratch**. Also the supported way to carry the data to
another machine.

> These are **throwaway local-demo data** (the deterministic seed datasets). They
> contain demo login password-hashes and the local stack's default container
> connection strings — **not** production secrets. The **vault42** zero-knowledge
> store and **redis** cache are deliberately excluded. The secret scanners
> (gitleaks / trufflehog) allowlist `data-snapshots/archives/` for this reason.

## What's inside (`archives/`, ~12.5 MB total)

| Engine | Files | Size | Contents |
|--------|-------|------|----------|
| **postgres** | 8 | ~3.6 MB | `postgres` (osionos + auth + control-plane), `commerce`, `gourmand`, `agency`, `red-tetris`, `website`, `realtime` + `globals.sql.gz` (roles, no passwords) |
| **mysql** | 2 | ~210 KB | `ops`, `mini_baas` |
| **mongodb** | 4 | ~1.1 MB | `activity`, `mini_baas`, `mini_baas_ai`, `mini_baas_analytics` |
| **mssql** | 1 | ~457 KB | `finance` |
| **dynamodb** | 6 | ~22 KB | `alerts`, `device_events`, `devices` (schema + items) |
| **minio** | 1 | ~7.3 MB | storage-bucket objects (uploaded files) |

Excluded: **vault42** (ZK secrets), **redis** (cache). `MANIFEST.json` lists every
file with its `sha256` and byte size.

Each dump uses its engine's native, restorable format: Postgres custom-format
(`pg_restore`), Mongo gzipped BSON archive (`mongorestore`), MySQL SQL, MSSQL
native `BACKUP`, DynamoDB schema+items JSON, MinIO object tar. Any file above
95 MB is auto-split into `*.partNN` (and reassembled on restore) to stay under
GitHub's 100 MB/file limit — currently nothing needs splitting.

## Restore on another machine / a fresh clone

```bash
# 1. bring the backend up (creates empty databases)
make -C apps/grobase up            # or: cd apps/grobase && make up EDITION=full

# 2. load the snapshot (DESTRUCTIVE: replaces those databases)
CONFIRM=1 apps/grobase/data-snapshots/restore-databases.sh

# 3. some services cache state — restart them to pick the data up
docker restart mini-baas-minio mini-baas-realtime
```

The restore is idempotent (drop-and-replace) and only touches the engines whose
containers are running. The primary osionos login is **dev.pro.photo /
`Osionos123!`**; other tenants' accounts come from the same datasets (agency,
gourmand, red-tetris, …) — see `../scripts/seed/` for the generators.

## Regenerate the snapshot (after changing the data)

```bash
apps/grobase/data-snapshots/snapshot-databases.sh
```

Re-discovers running engines, re-dumps each, rewrites `MANIFEST.json`, and
size-guards every file. Commit the updated `archives/`.

## Helper images

`snapshot`/`restore` shell out to two throwaway images on the `mini-baas_mini-baas`
network (the server images don't bundle the client tools): **`mongo:7`**
(`mongodump`/`mongorestore`) and **`amazon/aws-cli`** (DynamoDB). Postgres, MySQL,
MSSQL and MinIO are dumped in-container.
