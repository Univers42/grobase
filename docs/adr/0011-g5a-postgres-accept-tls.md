# 0011 — The central Postgres accepts TLS behind an opt-in overlay

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, C1–C8), code in G5a. Not on the VM: C7.

## Problem

G5 wants TLS on every hop. The first hop is the central Postgres, and it is the riskiest one:

- **Every service shares it.** PostgREST, GoTrue, Debezium, realtime, the outbox and the data
  plane all dial `postgres:5432`.
- **The switch is silent.** libpq, pgx and pgjdbc default to `sslmode=prefer`. The moment the
  server says `ssl=on`, those clients upgrade to TLS without any config change of their own. If a
  handshake then fails, it fails in a service nobody touched.
- **Any change recreates the database.** Editing the `postgres` service in `data-engines.yml`
  recreates the central DB container on the next `make up` on every host, the VM included.

## Decision

- **Overlay, not an env check.** `orchestrators/compose/docker-compose.engine-tls.yml` replaces
  the entrypoint, mounts the cert directory and adds a tmpfs. `00-config.mk` adds it to `DC` only
  when `ENGINE_TLS=1` is set, from the environment or from an `ENGINE_TLS=` line in `.env.local`.
  - Without the flag the resolved `postgres` service is byte-identical to before, so a host that
    never opted in does not recreate its database.
  - An `${ENGINE_TLS:-0}` test inside the service would change the service definition on every
    host, so it was rejected.
- **The cert comes from its own script.** `scripts/certs/generate-engine-cert.sh` signs a server
  cert with the existing local CA from `generate-localhost-cert.sh`:
  - SANs: `postgres`, `db`, `mini-baas-postgres`, `localhost`, `127.0.0.1`.
  - Validity: 397 days.
  - Output in `certs/engines/`: `engine.pem`, `engine-key.pem` (0600) and `ca.pem`, a public copy
    of the CA.
  - It reuses a cert that still verifies, has more than 30 days left and carries the SANs.
- **Only `certs/engines` is mounted.** It is mounted read-only, with `create_host_path: false`.
  `certs/` itself is never mounted, because it holds the CA key.
- **The key copy lives on a tmpfs.** `engine-tls-entrypoint.sh` copies the key and cert into the
  tmpfs `/run/engine-tls` (0700), with the key at 600 and owned by postgres. It then execs the
  image's own `docker-entrypoint.sh` with `ssl=on` and the two file settings.
  - Postgres refuses a key it does not own.
  - The bind mount keeps the host's owner.
  - A key under PGDATA would end up in every backup.
- **Fail closed.** `ENGINE_TLS=1` with no cert stops the container with the remedy in its log. It
  never falls back to plaintext.
- **Accept mode only.** `ssl=on` does not require TLS: a client that says `sslmode=disable` still
  connects. Rejecting plaintext (`hostssl`-only `pg_hba`) is a later G5 step, once every
  dependent is shown to negotiate.

## Pool fix found on the way

`data-plane-pool` could not open a Postgres mount whose DSN asked for verification:

- tokio-postgres 0.7.18 parses only `disable`, `prefer` and `require`.
- It rejected `sslmode=verify-full` and `verify-ca` as "invalid connection string".
- The pool's `TlsMode::Verify` path was therefore unreachable.

`conn::wire_dsn` now hands tokio-postgres `require` in their place:

- `require` keeps the handshake mandatory.
- Verification stays with the rustls connector, chosen from the original DSN: webpki roots plus
  `DATA_PLANE_TLS_CA_FILE`, with the host name checked.

The unit test `verify_modes_reach_tokio_postgres_as_require` shows both halves: the raw DSN fails
to parse, and the rewritten one parses as `Require` while `effective_tls_mode` stays `Verify`.

## Consequences (the devil's conditions)

- **C1:** nothing that runs on every host mints the engine cert. `expose.sh`, `make certs` and
  `generate-localhost-cert.sh` do not call it. m247 checks this statically.
- **C2:** TLS needs both `ENGINE_TLS=1` and the cert. The default service has no `ssl` setting
  (m247 static, and live leg A: `SHOW ssl = off`).
- **C3:** the key is 600 and owned by postgres on a tmpfs, and there is no key or cert under
  PGDATA (m247 live leg B).
- **C4:**
  - A verify-full session checks `pg_stat_ssl` for its own pid.
  - A host name outside the SANs is refused by verification.
  - Plaintext is tested with an explicit `sslmode=disable`, never with a defaulted `prefer`.
- **C5:** CI runs the Postgres engine-conformance leg twice:
  - Once as before, a fresh boot with no cert.
  - Once with `tls: 1`, which mints the cert, composes the overlay and runs m27 with the pool on
    `verify-full` (`M27_PG_TLS_CA`). It then runs m247 live and the stack inventory.
- **C6:** `M247_STACK=1` lists every client backend by `application_name` with its `ssl` flag, and
  fails if a logical slot does not advance after a WAL message. Run it on any stack composed with
  the overlay before the VM window.
  - Caveat: a consumer that confirms lazily can need a longer `M247_SLOT_WAIT`.
- **C7:** no VM pin or rollout outside a confirmed G5 window, announced as a recreate of the central
  Postgres, with every network path probed after (`vm-is-the-cloud`).
- **C8: renewal.** Re-run `generate-engine-cert.sh`, then recreate `postgres`:
  `make up` with `ENGINE_TLS=1`, or `docker compose … up -d --force-recreate postgres`. The running
  server holds a tmpfs copy of the old key until it is recreated. The script warns when it issues
  a new cert. Expiry is 397 days, and the reuse check renews inside the last 30.

## Not done here

Turning on this overlay moves these clients to TLS on their own: PostgREST, GoTrue, Debezium,
realtime, the outbox and psql. They are expected to keep working, because `prefer` accepts what
the server offers. None of them verifies the cert yet. That, and the other engines (Mongo,
Cockroach, Redis, MySQL/MariaDB, MSSQL, MinIO/Trino), are the rest of G5.
