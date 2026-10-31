# 0032 — The nine Node services that dial the central Postgres verify its certificate, through one opt-in overlay

- Status: proposed. devil ruled PROCEED-WITH-CONDITIONS on 2026-10-30 (NP1–NP12), and re-ruled the live gate's shape the same day (W1–W6). Nothing changes on the VM.
- Date: 2026-10-30
- Deciders: devil (ruling). Whoever composes `ENGINE_TLS_ENGINES=pg-clients` lives with the outcome.

## Context

- G5a (ADR 0011) made the central Postgres accept TLS beside plaintext. Its clients still dial with no `sslmode`, so every internal pool is plaintext on the wire.
- Only nine Node services dial that Postgres: query-router, outbox-relay, permission-engine, schema-service, gdpr-service, newsletter-service, session-service, mongo-api and storage-router. ai, analytics, email and log import no `PostgresModule`, `AuditModule` or `pg`.
- A bad CA is not loud everywhere:
  - The six services on `PostgresModule` connect eagerly at boot (`libs/database/src/postgres/postgres.service.ts:41-80`), so they refuse to start.
  - query-router has no `PostgresModule`. Its outbox emission is caught and only WARNs (`src/apps/query-router/src/query/query.service.ts:507-511`, and the transaction twin at `:690-695`).
  - The audit writer behind mongo-api, storage-router and query-router WARNs `audit_log write failed` (`libs/common/src/audit/audit-writer.ts:199-200`).
  - So the write succeeds while its outbox event and audit row are lost.
- `${DATABASE_URL}?sslmode=…` on a DSN that already carries `?a=b` turns that parameter's value into `b?sslmode=verify-full`. sslmode is then lost from the query, and the operator's parameter is corrupted.
- `AUDIT_DATABASE_URL` cannot be suffixed by a static overlay. `${X:+…}` renders `""`, and `"" ?? DATABASE_URL` keeps `""`, which disables audit (`audit.service.ts:122`).

## Decision

- `orchestrators/compose/docker-compose.engine-tls-pg-clients.yml` changes exactly those nine services (NP2). Each one:
  - gets `DATABASE_URL` + `?sslmode=verify-full&sslrootcert=/etc/engine-pg-ca/ca.pem`;
  - gets one read-only bind of `${ENGINE_TLS_CERT_DIR}/ca.pem`;
  - gets nothing else. No `PGSSLMODE`, `PGSSLROOTCERT` or `NODE_EXTRA_CA_CERTS`, and the overlay never names `AUDIT_DATABASE_URL` (NP3, NP5).
- It is composed only when `ENGINE_TLS_ENGINES` lists `pg-clients`, through the existing per-engine foreach. Make errors without `ENGINE_TLS=1`, and with any `COMPOSE_FILE` other than `docker-compose.yml`: the monolith is refused (NP1). It is never in `PROD_FILES`.
- `up`, `bench-startup` and `cutover-%` first run `scripts/certs/check-pg-clients-tls.sh` (NP4, NP6). The check refuses:
  - a `DATABASE_URL` containing `?` or `#`;
  - a non-empty `AUDIT_DATABASE_URL`;
  - an `engine.pem` that `ca.pem` did not sign, that expires within 30 days, or whose SANs lack the DSN host.
- Beside `ENGINE_TLS_ENGINES=data-plane`, query-router keeps both trusts: `NODE_EXTRA_CA_CERTS` for the data plane, and the DSN's `sslrootcert` for Postgres (NP11).

## Out of scope (written down, NP10)

- **Go clients.** tenant-control copies the `DATABASE_URL` query into the self-serve mount DSNs it persists (`cmd/tenant-control/mount_appsselfserve.go:44` → `internal/tenants/selfserve_apps_spec.go:55-61`). The Rust data plane then ignores `sslrootcert` (data-plane-pool `tls.rs:71`), so suffixing it is a one-way door. That waits until `appDSN` strips TLS parameters. gotrue reads `GOTRUE_DB_DATABASE_URL`, and its image's TLS behaviour is unmeasured.
- **The pooler.** Tenant DSNs keep whatever their owner saved; this overlay changes only the central `DATABASE_URL`.
- **The VM.** There is no VM pin and no window. A VM rollout is a G5 window of its own, one engine per window (NP12).
- **The empty `AUDIT_DATABASE_URL` trap.** `base/_common.yml` passes `AUDIT_DATABASE_URL` through, so a shell that exports it empty disables audit with or without this overlay. That is pre-existing and not fixed here; the preflight only refuses a non-empty value.

## Alternatives considered

- `PGSSLMODE`/`PGSSLROOTCERT` in the environment. Rejected: they also reach tenant pools and the automations pool, and would force verify-full onto tenant DSNs whose CA the service does not hold (NP3).
- One overlay that also rewrites `AUDIT_DATABASE_URL`. Rejected: the render cannot express "suffix when set, else unset" (Context).
- Making the outbox and audit failures loud. That is a behaviour change to the write path and needs its own ruling; the gate pins today's swallow instead (W2).

## Consequences

- Verified by `scripts/verify/m264-pg-clients-tls.sh`, in the `pg-clients-tls` CI job:
  - **Static.** It checks opt-in, the derived dialer set, the render diff, no drift in eight other configurations, and the preflight's ten cases.
  - **Live** (`M264_LIVE=1`). The nine run, built from the commit, in a scratch project against a TLS Postgres. The legs:
    - **W1.** The probe calls the compiled `OutboxService.emitForQuery` with a mutating op (insert) inside query-router's own container. `outbox_events` gains one row.
    - **W2.** `src/apps/query-router/src/query/query.outbox-swallow.spec.ts` pins both swallows. Each one keeps the caller's result and WARNs `outbox emission failed` / `txn outbox emit … failed`.
    - **W3.** Every probe is `docker exec` without `-e`. It asserts that `PGSSLMODE`, `PGSSLROOTCERT`, `NODE_EXTRA_CA_CERTS` and `AUDIT_DATABASE_URL` are unset and that `DATABASE_URL` carries the suffix, in all nine.
    - **W4.** Under an unrelated CA, the six `PostgresModule` services log a certificate refusal and never turn healthy. query-router, mongo-api and storage-router stay up, asserted by `/health/live`: query-router cannot be compose-healthy without adapter-registry.
    - **W5.** The audit loss under the wrong CA is asserted by its real line, `audit_log write failed`, not `pool error`, with zero rows landing.
    - **W6.** The probes build `OutboxService` and `AuditService` by hand from the image's `dist`. They prove the pool each one builds from the rendered env, not the controller → DI wiring that calls it. The automations pool is covered only because it shares `DATABASE_URL`. Both limits are the live lib's `Caveat:`.
  - `pg_stat_ssl`, sampled by container IP, shows TLSv1.3 for all nine and no plaintext backend (NP7). `psql sslmode=disable` still works, because the server is in accept mode, and a tenant DSN without sslmode still dials plaintext from query-router (NP8).
  - The parse matrix reads the shipped versions from `node_modules`, pg 8.20.0 and pg-connection-string 2.12.0 (NP12).
- A wrong `ca.pem` is caught at `make up` by the preflight, not by the services. Three of them would otherwise run on, losing events without a loud failure.
- Rotating the Postgres CA now means recreating the nine services, after `ca.pem` changes and before the old CA is retired.
