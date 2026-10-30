# 0015 — Every pool SQLite connection is hardened (G2-S1a)

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, S1–S14). Always on; no flag, no deploy.

## Problem

The pool's SQLite adapter opened whatever path a DSN named, with no authorizer, no limits and
no defensive mode. A raw read (`/v1/admin/raw` with `expect_rows=true`) ran on a pooled reader
outside any transaction, so `ATTACH '/tmp/other.db'` or `VACUUM INTO` reached any file the
process can write. `PRAGMA temp_store_directory` and `hard_heap_limit` are process-global, so
one mount could reach nano, pb and every other tenant.

## Decision

- **One function, `harden`** (`crates/data-plane-pool/src/sqlite/harden.rs`), exported as
  `harden_sqlite_connection` so nano/pb are one call away. It runs on every reader
  connection through deadpool's `post_create` hook (not only the first checkout) and on the
  writer in `open_writer_conn`. The adapter's own pragmas (`tune`) run first, before the
  authorizer would refuse `journal_mode`.
- **Two independent locks on ATTACH.** `SQLITE_LIMIT_ATTACHED=0` and an authorizer deny of
  ATTACH/DETACH. `sqlite3Vacuum` makes no auth check of its own; VACUUM INTO reaches the
  authorizer only through its inner ATTACH, so the limit is what does not depend on that.
  Tests run each lock alone, on both the read and the write path.
- **Authorizer** also refuses the `load_extension` function and a write (a pragma with a
  value) to `temp_store_directory`, `data_store_directory`, `soft_heap_limit`,
  `hard_heap_limit`, `writable_schema`, `trusted_schema`, `journal_mode`, `locking_mode`,
  compared case-insensitively. Pragma reads (`table_info`, `pragma_foreign_key_list`) pass.
- **DBCONFIG**: `DEFENSIVE` on, `TRUSTED_SCHEMA` off.
- **Paths refused by shape, before any file opens.** The bundled build compiles
  `SQLITE_USE_URI`, so dropping `SQLITE_OPEN_URI` would not disable `file:` URIs; only a
  string refusal works. A path starting with `file:`, containing `?`, or naming the server's
  `nano_meta.db`, `pb_meta.db`, `pb_logs.db` (or their `-wal`/`-shm`/`-journal`) is refused.
  The error names the shape, never the path. `main.db` stays allowed: it is nano's default
  pool mount.
- **Deps**: rusqlite features `hooks` and `limits` added to `bundled`.

## What it does not do

- **It does not isolate tenants.** Any `/v1` caller can still put `sqlite:///tmp/<other>.db`
  in the body `inline_dsn` until G1 enforce and mount provenance land.
- **No root confinement yet.** `DATA_PLANE_SQLITE_ROOT` and the writer's
  `SQLITE_OPEN_NOFOLLOW` are G2-S1b. Under that root a `tenant_id` from the body is still
  spoofable before G1 enforce.
- **Symlinks and hardlinks** to a server file under another name pass the name check, and the
  reader pool follows a symlink (deadpool-sqlite hard-codes `Connection::open`; a custom
  Manager is the escape hatch). Both carry a `Caveat:` in the code.
- **nano and pb raw paths are not hardened** (U5). They open their own connections.
- **Plain `VACUUM` is now refused** (its inner ATTACH hits the limit). No in-repo caller uses it.
- **VM**: before the image is promoted, a read-only count of registry sqlite mounts whose DSN
  holds `file:` or `?` must be 0 (S2). Counts only, never values.

## Evidence

- `cargo clippy --workspace --all-targets -- -D warnings` clean; `cargo test --workspace`
  1126 passed, 0 failed; `cargo test -p data-plane-pool --features dynamodb --lib sqlite`
  40 passed (rust toolchain image, 2026-10-30).
- Mutation: with the reader hook skipping `harden`, two adapter tests fail
  (`a_second_reader_connection_is_tuned_and_hardened_too`,
  `raw_attach_is_refused_on_the_read_and_the_write_path`).
- `scripts/verify/m27-conformance.sh sqlite`: 12 passed, 8 skipped, 0 failed, unchanged.
  Wall time, warm-up then 5 runs per tree: median 0.724 s before, 0.701 s after (−3%, noise).
