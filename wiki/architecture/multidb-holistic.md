# Multi-database, multi-engine — the holistic plan (grobase half)

*What grobase can do today on each engine, what is missing, and the ordered work that
closes the gap. Every gap below cites the file that proves it. The osionos and
workspace half lives in groot `wiki/architecture/multidb-holistic.md`.*

Mapped 2026-10-29 from `develop` 450788ad and the live VM (`/opt/grobase`, a855f86b
+ uncommitted operator edits that this plan does not touch).

## Where we stand — capability matrix

Y = yes · P = partial · N = no. Truth source: `data-plane-core/src/capability.rs`
(boot-checked by `assert_capability_honesty`). The live VM `/v1/capabilities` lists the
same 10 engines.

| Operation | PG | CRDB | MySQL¹ | Maria | Mongo | SQLite | MSSQL | Redis | HTTP | Dynamo² |
|---|---|---|---|---|---|---|---|---|---|---|
| list / get / insert / update / delete / upsert | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| batch (≤1000) | Y | Y | Y | Y | Y | Y | Y | Y | N | P (25, non-atomic) |
| aggregate + group_by | Y | Y | Y | Y | Y | Y | Y | N | N | N |
| filter DSL | Y | Y | Y | Y | Y | Y | Y | N | P | P |
| sort | Y | Y | Y | Y | Y | Y | Y | P | P | N |
| cursor pagination | N | N | N | N | N | N | N | N | N | N |
| introspection (tables, columns, PK) | Y | Y | Y | Y | P | Y | P | N | N | P |
| FK introspection | Y | Y | Y | Y | N | N | N | N | N | N |
| list databases / schemas | N | N | N | N | N | N | N | N | N | N |
| structured DDL (5 ops) | Y | Y | Y | Y | P | P | N | N | N | N |
| indexes / constraints / FK create | N | N | N | N | N | N | N | N | N | N |
| views / functions / triggers | N | N | N | N | N | N | N | N | N | N |
| EXPLAIN / index advice | N | N | N | N | N | N | N | N | N | N |
| cross-request transactions | Y | Y | Y | Y | N³ | N | N | N | N | Y |
| savepoints / 2PC | N | N | N | N | N | N | N | N | N | P |
| TLS enforced under `SECURITY_MODE=max` | P⁴ | P⁴ | N | N | Y | — | P | Y | — | N |
| cross-mount relation | graph endpoint only, eventual (`graph.rs:13-22`) |||||||||| 
| cross-engine join | N — `Federate` lowered to NotImplemented (`plan.rs:343-353`) ||||||||||

1. The `mysql` image is Alpine MariaDB (`infra/docker/services/mysql/Dockerfile`, live
   `version()` = 11.4.12-MariaDB). Oracle MySQL 8.4 runs in CI as the `mysql8` m27 leg (G3).
2. Opt-in build (`--features dynamodb` + `DYNAMODB_ENGINE_ENABLED`). The repo default
   forward list omits it (`orchestrators/compose/base/data-plane.yml:10`); the VM
   overrides it. A fresh clone does not reproduce the deployed engine set.
3. The live Mongo is already replica set `rs0`; only the descriptor says no
   (`capability.rs:206-212`).
4. Max mode upgrades `sslmode=require` to verify but leaves a DSN with no `sslmode` in
   plaintext (`postgres/conn.rs:36-50`).

Not data-plane engines: Trino/Iceberg (Kong `/sql` passthrough, superuser, plain HTTP,
its `mongodb` catalog answers Unauthorized live) and MinIO (storage-router).

## The five gaps that decide the order

1. **The data plane trusts its caller.** `/v1/query`, `/v1/schema/ddl`, `/v1/admin/raw`
   and `/v1/transactions` take identity, roles and the inline DSN from the request
   body; the router stack has no auth layer (`data-plane-server/src/routes/mod.rs:105-140`,
   `routes/admin.rs:44-57`). Any container on the bridge network is `service_role`.
   Query-router DDL checks only `AuthGuard` + a `confirm` flag
   (`schema.controller.ts:29`, `schema.service.ts:~153`), so a read-scoped key can drop a
   table. Every DDL, contract and migration feature below widens this hole, so it closes
   first.
2. **No TLS inside the stack.** Postgres `ssl=off` (0/15 sessions encrypted), Mongo
   `tlsMode` disabled, Cockroach `--insecure`, Redis no TLS and no password, compose
   `SECURITY_MODE=baseline` + `DATA_PLANE_TLS_INSECURE=1`
   (`orchestrators/compose/base/data-plane.yml`), internal pools `NoTls`
   (`outbox.rs:47`, `automations.rs:39`). MySQL/MariaDB/Dynamo have no posture check
   (`reject_insecure_tls(` is called only at `redis/adapter.rs:57`, `mongo/adapter.rs:70`).
3. **A mount is a flat row.** `tenant_databases` has no host/database/file/TLS/health view,
   no PATCH (`adapterregistry/handler.go:50-55`), and `SchemaDescriptor` is
   `{engine, tables}` (`schema.rs:82-86`). The UI cannot say which DBMS, server or file a
   database lives on. A self-serve API exists but nothing calls it
   (`tenants/builder.go:83-85`, gate m131, flags `BUILDER_ENABLED` +
   `TENANT_SELFSERVE_ENABLED`).
4. **No relation survives an engine boundary.** `ForeignKeyRef {table, column}` has no
   mount (`schema.rs:46-51`); there is no contract table, no integrity check, no cascade;
   outbox events carry no mount id (`outbox.service.ts:69-96`), functriggers match only
   aggregate + event type (`functriggers/models.go:108-125`), automation actions write
   only the same table (`automations.service.ts:175-180`).
5. **CI proves 2 of 10 engines, by hand.** Live conformance runs only in
   `nightly-proof.yml` on `workflow_dispatch`, postgres + mongo, `continue-on-error`
   (`nightly-proof.yml:351,422-430`). Per-PR `cargo test` skips without
   `CONFORMANCE_ENGINE` (`tests/conformance.rs:15-37`). Gates m22, m26, m88, m131, m174,
   m176, m181, m230 exist and are wired into no workflow.

## The work — grobase epics, in order

Each item lands as atomic commits on `feat/multidb-holistic`, with a `scripts/verify/m<NN>`
gate and a CI job. New behaviour ships behind a flag, OFF by default, until its gate is
green in CI. Gate numbers are reserved here so two items never collide.

### Devil verdict (2026-10-29) — PROCEED-WITH-CONDITIONS overall

Scores: blast 5 · reversibility 3 · cost 5 · confidence 2. The conditions below are
acceptance criteria, folded into each item. Order changes: G0 is new and first; the
DEFAULT allowlist (G2a) ships before G1; N-22 moves into Phase 0; G3 and G7 run in
parallel with G1; G11 splits into G11a (allowed) and G11b (blocked).

| Item | Verdict | Lifts / key conditions |
|---|---|---|
| G0 Trino `/sql` | BLOCK until probed | read-only probe needs a human go; then ACL or remove |
| G2a DEFAULT allowlist | PROCEED — first unit | typed grammar, proptest, rg inventory of existing defaults |
| G1 | PwC | no Kong signer; `/v1/capabilities` open; body cap = 2 MiB; shadow ≥ 24 h before enforce |
| G2 | PwC | dial-time guard with IP pinning for every engine; provenance; N-22 closed |
| G3, G7 | PwC / PROCEED | CI only; G3 green before G2's dial guard |
| G4 | PwC | G4b re-ruled 2026-10-29: pool key carries a credential revision, not a DSN hash (ADR 0010, C1–C12) |
| G5 | PwC | one engine per confirmed VM window, accept-TLS before require |
| G6, G8, G9, G10 | PwC | after G1 enforce; dry-run first; parity before deleting a DDL path |
| G11a / G11b | PwC / BLOCK | `db_id` + `mounts[]` only; `write_mount`/`run_function` wait for a tenant principal |
| G12 | BLOCK | G1 enforced; slug↔UUID tenant mapping proven; O5 scope answer; ADR 0008 |
| G13 | BLOCK | Trino auth + TLS + per-tenant catalogs, never as platform `POSTGRES_USER` |

### Phase 0 — close the open doors (blocks everything)

**G0 · Close the Kong `/sql` → Trino route** — gate m206 (existing; m256 left unused)
- Static evidence (VM, read-only, 2026-10-29): `trino-route` `paths: [/sql]` carries
  key-auth + jwt with `anonymous` and no `acl` (`kong.yml:851-879`); Trino has no
  authentication configured; its catalog connects as `${ENV:POSTGRES_USER}`.
- [ ] Read-only probe through the WAF with the public anon key, status codes only —
      **needs an explicit human go**.
- [x] Repo: `acl allow [baas-admin]` on `trino-route` (ba9f9adb). No caller of `/sql`
      exists in grobase, the SDKs, osionos or the groot apps; the service key still passes.
- [x] m206 lists `/sql` as service-only: anon key → 403 by the acl, service key passes.
      Against the old `kong.yml` it fails "trino-route (/sql) is service-only but not acl
      baas-admin". Runs in CI's Security gates job (`run-gate-battery.sh m206-kong-admin-acl`).
- [ ] VM rollout only in a confirmed window — the VM's `kong.yml` carries uncommitted
      operator edits, so the change is merged by hand, never overwritten.

**G2a · DEFAULT expressions: allowlist, not blocklist** — part of m244, first PR
- [x] One validator, `data-plane-core::default_expr` (5594134e), replaces the blocklist:
      numeric literal, single-quoted string with `''` as the only escape (no backslash:
      MySQL reads `\'` as a quote), TRUE/FALSE/NULL, `now()`, `CURRENT_TIMESTAMP`,
      `CURRENT_DATE`, `gen_random_uuid()`, `uuid_generate_v4()`, ≤ 1024 bytes. Every
      builder already calls it (`postgres/ddl.rs`, `mysql/schema.rs`, `sqlite/schema.rs`).
- [x] RED first: `'x', DISABLE ROW LEVEL SECURITY` and 13 more smuggling forms failed on
      the blocklist, pass now (`tests/sec_schema_ddl.rs`).
- [x] Proptest: an accepted input with `,` `)` `'` `\` never leaves its literal; any text
      quoted with doubled quotes is accepted. RED seeds kept in `.proptest-regressions`.
- [x] rg inventory: every existing default is accepted or already expected to 400/422;
      osionos sends no defaults, so no shadow arm was needed.
- Gate: `cargo test --workspace` + clippy `-D warnings` in CI (ci.yml Rust job) — green.

**G1 · Authenticate the data plane, authorize DDL** — gate m243 · ADR 0007
- [x] Inbound service auth on every `/v1/*` route of data-plane-server (HMAC
      service token already used for outbound `verify_key` / `resolve_mount` — reuse,
      do not add a second scheme). Health + metrics stay open. *(G1a:
      `routes/inbound_auth.rs`, `ServiceAuthVerifier` in `service_auth.rs`.)*
- [ ] Identity comes from a verified claim, never the request body; inline DSN accepted
      only from the authenticated query-router identity.
- [ ] Query-router `POST /:dbId/schema/ddl` requires the permission engine's `ddl`
      decision (owner/admin role, or an API key with an explicit `ddl` scope). Bypass
      path (`bypass.rs:145`) stops treating `write` as DDL.
- [~] Flag `DATA_PLANE_INBOUND_AUTH` (default OFF one release, then ON); compose sets it.
      *(G1c: `base/data-plane.yml` passes it, default `off`, with
      `SERVICE_AUTH_SKEW_SECS`. Default ON waits for the enforce rollout.)*
- [ ] m243: unauthenticated `/v1/admin/raw` → 401; forged body identity → 403;
      read-scoped key DDL → 403; owner DDL → 200; an edge function POSTing unsigned to
      `/v1/admin/raw` → 401 and cannot read `INTERNAL_SERVICE_TOKEN`.
- [ ] No Kong Lua signer (sandbox allows only `cjson.safe`, and it would sign client
      bodies): `/admin/v1/{migrate,rotate}` move to a tenant-control route that builds the
      identity and signs via `postAdmin`; SDK `admin.ts:114-122` keeps working (test).
- [x] `/v1/capabilities` stays open (unsigned probes in m72, m101, m74, m20).
- [x] Body buffered with a 2 MiB cap (today's axum default) → 413 before hashing.
- [x] Cross-language test: Rust verifier accepts a TS-signed `postJson` (string body,
      explicit `Content-Type`). Refuse to start if `RUST_DATA_PLANE_URL` has a path.
      *(G1b: `rust-data-plane.proxy.spec.ts` proves the header signs the exact bytes
      sent; the TS, Go and Rust signers share one golden vector set.)*
- [x] Commit/rollback get the tenant check execute already has (`transactions.rs:130-137`).
      *(G1d: `take_for_tenant` checks and removes under one lock; the router sends
      the identity; an empty body still finalises, as before.)*
- [~] `applyDdl` fails closed with no identity (today falls back to `userId`,
      `schema.service.ts:159`); DDL on static mounts only for service_role; the JWT role
      vocabulary is proven before the JWT branch is coded.
      *(G1e: `applyDdl` refuses 403 without a verified tenant, before any lookup.
      G1g (ADR 0009): only a Kong-signed app key with `write`/`admin` may run DDL, so a
      read-only key and a JWT user get 403; JWT DDL is declined
      (`.out-of-scope/jwt-user-schema-ddl.md`). Static mounts: #78.)*
- [~] Modes off / shadow / enforce. Off = today, proven by m18 + parity unchanged.
      *(G1a: modes + flag land, default off. G1b: the query-router signs its
      `/v1` calls. G1c: compose passes the flag, default off.)*
      Enforce on the VM: human go, ≥ 24 h shadow with zero `would_deny`, rollback =
      flag → shadow + recreate data-plane-router-rust and query-router only.
      Shadow live on the VM since 2026-10-29 23:52Z (main 69500ecf images). Live m249
      across 7 mounts: 305 internal POSTs signed, 0 FAIL. One deliberate unsigned probe at
      23:54:51Z proves would_deny reaches the log. Enforce is eligible from 2026-10-30 23:52Z.
- [x] Before enforce: sweep of osionos bridge + groot apps for direct `:4011` callers.
      *(2026-10-30: none in groot apps or the osionos bridge, which go through Kong; on the
      VM only query-router and tenant-control name the data plane. Live-stack verify scripts
      (m18 `--live`, m174) call only `/v1/capabilities`, which stays open; `/data/v1` is
      outside the layer.)*
- [x] Audit logs carry route, outcome and reason — never body, signature or token.
      *(`inbound_auth.rs:143,150`: `route` is the `MatchedPath` template, `reason` one of five
      fixed strings, `service_auth.rs:113-121`.)*
- [ ] Before the compose default flips to ON: the 14 scratch-stack gates that boot their own
      data plane and POST `/v1/query` or `/v1/transactions` unsigned (m72–m75, m80, m85, m88,
      m94, m98, m101, m103, m120–m122) pass the service token. They run with the flag unset
      (off), so VM enforce does not touch them.
- [x] ADR 0007 records the residuals: one shared token (23 compose refs, measured) lets any
      platform service assert any identity (lifted by a `v2.<kid>` scheme later); replay
      inside the 120 s skew; inline DSN from any token holder.

**G2 · DSN hardening** — gate m244
- [ ] One dial guard in data-plane-pool for every engine, run at DIAL time with the
      resolved IP pinned (reuse `http/validate.rs` classification) — beats DNS rebinding
      and post-connect redirects (Mongo SRV/SDAM, PG multi-host, Redis MOVED, TDS
      routing). Covers DynamoDB `endpoint=`; tenant mounts never fall back to the default
      AWS credential chain.
- [ ] Mount provenance (platform / tenant): platform mounts keep internal hosts; tenant
      private and Tailscale ranges via an explicit per-tenant allowlist, no blanket block.
- [ ] SQLite: path built server-side as `<root>/<tenant>/<mount>.db`; `file:` and `vfs=`
      rejected; ATTACH and VACUUM INTO denied on tenant mounts.
- [ ] N-22: adapter-registry identity HMAC on by default; Vault ref namespaced
      `{prefix}/{tenant_id}/{reference}` server-side; DSN check inside `Validate`.
- [ ] m230 extended with a canary password through register and error paths in Rust, Go
      and TS, then wired into CI.

**G3 · Per-PR engine conformance, all engines** — gate m245 + CI matrix
- [x] CI job `engine-conformance` with a matrix over the 10 engines, each starting only
      its own compose profile; blocking, not `continue-on-error`. m27 now finds the
      network from whichever engine container runs (it read only postgres before). Local
      run 2026-10-30, one engine per scratch compose project: all 7 stack engines green.
- [x] Wire dynamodb and http into `tests/conformance.rs` and `m27-conformance.sh`.
      Both run on throwaway upstreams (a stdlib REST mock, dynamodb-local), so CI job
      `engine-conformance` already gates sqlite · http · dynamodb on every PR with no
      stack; the seven stack engines are the rest of the matrix item above. The http
      adapter now reads a Get's 404 as an empty result, like every other engine.
- [x] Battery gains: structured DDL round-trip (`ddl_round_trip`, where schema_ddl and
      introspect), FK introspection (`fk_introspect`; sqlite and mssql describe now report
      `references`, mssql its primary key too), and route honesty (`route_honesty`: every
      route flag marked false refuses with a typed refusal). Local 2026-10-30: Rust gate
      1052 passed / 0 failed; m27 rc=0 on sqlite, postgresql, mysql, mongodb, mariadb,
      cockroachdb, mssql, redis, http.
- [x] Typed-value round-trip in the battery (feeds G7). `type_round_trip` in engine-conformance (`src/type_checks.rs`) ports m249's 12 cases and gap ledger to the pool surface; a gap that starts passing fails, and `mysql` picks its ledger by `SELECT VERSION()` (MariaDB vs Oracle MySQL). Local 2026-10-30, all 9 engines rc=0: postgresql/cockroachdb 1 gap (c_int), mysql+mariadb 4, mongodb 4, sqlite 7; mssql/redis/http SKIP (no schema_ddl).
- [x] Add a real Oracle MySQL 8 service (profile `mysql8`) so MySQL ≠ MariaDB is proven.
      `infra/docker/services/mysql8`: Oracle's 8.4.9 glibc minimal tarball, sha256-pinned,
      on bookworm-slim, uid 999. m27 runs it behind the `mysql` descriptor and asserts
      `mysqld --version` is MySQL Community Server. Local 2026-10-30: 12/12 PASS, ledger
      3 gaps (c_int, c_ts, c_uuid; JSON is a real type on MySQL). It found one adapter bug,
      now fixed: CREATE TABLE left PK columns nullable, which MariaDB coerces and MySQL
      refuses (ERROR 1171); `mysql_column_clause` now renders a PK column NOT NULL.
- [x] Wire existing unwired gates: m22, m26, m88, m131, m174, m176, m181. Static legs m22/m26/m181/m176 run in the CI static job (m22, m26 and m181 were stale after the engine split into directories and the multi-line PK selector; fixed with the same strictness). Scratch gates m131 and m88 joined the `--enterprise` battery (local 2026-10-30: m131 7/7, m88 8/8, rc=0). m174 stays a VM live gate: it needs the extra-engines seed on a stack and SKIPs without Kong.
- [x] The dynamodb opt-in is in the env schema and `.env.example`: `DYNAMODB_ENGINE_ENABLED`,
      `DATA_PLANE_FEATURES`, `DATA_PLANE_IMAGE_SUFFIX` (infra/config/env/schema.json says
      why they go together). The default stays off. m214 PASS, `render-example.sh --check` rc=0.

### Phase 1 — say what a database is bound to

**G4 · Mount descriptor + PATCH** — gate m246
- [x] `GET /databases/{id}/descriptor`: engine, host (or file for SQLite), database,
      isolation, credential mode (inline/vault/cmek), requested TLS, last health. Never a
      secret, never a password, never the raw DSN.
- [ ] Descriptor: server version, negotiated/verified TLS and capability flags — need a
      live probe; the descriptor reads the row only and never dials (G5 fills TLS).
- [x] `PATCH /databases/{id}`: rename and rotate the credential (inline DSN or vault ref;
      TLS params travel in the DSN). The id stays, so `baas:<dbId>` bindings survive.
- [x] Same through the self-serve `/v1/tenants/me/mounts/{id}` surface (scope `write`,
      MountBuilder only).
- [x] PATCH reaches the data plane: migration 094 `revision` → `credential_ref.version`
      `r<n>` → a new pool key; the old pool reaps at `idle_ttl` (ADR 0010).
- [x] Platform-provenance mounts show no internal host (descriptor); PATCH is
      service-token gated. Authz from the G1 identity stays with G1.
- [x] m246: descriptor carries no secret; PATCH routed on both hops, service-token gated,
      revision in both DDL paths, no literal pool version in query-router.

### Phase 2 — TLS everywhere

**G5 · TLS on every hop, enforced, gated** — gate m247
- [ ] Internal CA (reuse the WAF's local-dev CA tooling) issues server certs for every
      engine container; compose turns on server TLS: Postgres `ssl=on`, Mongo
      `requireTLS`, Cockroach secure mode, Redis TLS port + ACL password, MySQL/MariaDB
      `require_secure_transport`, MSSQL force encryption, MinIO/Trino HTTPS.
  - [x] G5a — Postgres accepts TLS behind `ENGINE_TLS=1` (overlay, own cert script, key on
        tmpfs, fail-closed without cert); default byte-identical (ADR 0011; m247 static + live
        A/B/C; CI postgres leg twice). Accept mode only — plaintext refusal is a later step.
  - [x] G5b mongo — `ENGINE_TLS_ENGINES=mongo` (own overlay, `certs/engine-tls/mongo`,
        root → setpriv uid 999); ADR 0012; m247 mongo A/B/C green locally 2026-10-30; CI
        mongodb leg twice.
  - [x] G5b redis — `ENGINE_TLS_ENGINES=redis`: TLS on 6380, never published, 6379 plaintext;
        root → setpriv uid 100 (image gains util-linux setpriv); m247 redis A/B/C green
        locally 2026-10-30 (SAN legs via openssl, redis-cli skips host names); CI m247 step.
  - [x] G5b mariadb — `ENGINE_TLS_ENGINES=mariadb`: the CA-signed cert replaces 11.4's
        self-signed default, `command: ["mariadbd"]` restated, root → setpriv uid 100; m247
        mariadb A/B/C green locally 2026-10-30, m27 under the overlay 12 passed / 0 failed; CI
        mariadb leg twice. First boot drops install-db's passwordless root@<hostname>.
  - [ ] G5b `mysql` service (MariaDB, `data-plane` profile) — own overlay, `command: ["mysqld"]`
        restated (ADR 0012 C4, C12).
  - [ ] Clients verify mongo's and redis's certs (mongosh, mongo-init, mongo-api, pool, redis
        consumers); today plaintext.
- [ ] `DATA_PLANE_TLS_INSECURE` default 0; `DATA_PLANE_TLS_CA_FILE` points at the CA.
- [ ] `reject_insecure_tls` on MySQL/MariaDB/Dynamo/MSSQL; Postgres max mode turns
      "no sslmode" into `verify-full`, not plaintext.
  - [x] G5b-C10 — mysql/mariadb mounts: `SECURITY_MODE=max` refuses `verify_ca=false` /
        `verify_identity=false` (parsed options, so percent-encoded keys are caught) and trusts
        `DATA_PLANE_TLS_CA_FILE`; 3 unit tests.
  - [x] The pool opens `sslmode=verify-full`/`verify-ca` Postgres mounts (tokio-postgres
        0.7 refused them; `conn::wire_dsn`); m27 postgres over verify-full 12 passed / 0 failed.
- [ ] Internal pools (outbox, automations) and query-router → data plane use TLS.
  - [x] G5a C6 (local, 2026-10-30): Debezium sessions + walsender on TLSv1.3 under the
        overlay; the outbox slot decodes past an m247 probe in 1 s.
  - [ ] realtime's Postgres producer dials `NoTls` (`realtime-db-postgres`
        `producer/lifecycle.rs:109`): give it a TLS connector before any plaintext refusal.
- [ ] m247: `pg_stat_ssl` 100 % encrypted; each engine refuses a plaintext client;
      descriptor (G4) reports `tls: verified` per mount.
- [ ] Rollout on the VM is a separate, confirmed window (`vm-is-the-cloud`): every
      network path probed after.

### Phase 3 — origin model, creation target, migration

**G6 · Database origin: list and create databases/schemas** — gate m248
- [ ] `SchemaDescriptor` gains `databases[]` / `schemas[]` per engine (capability-flagged).
- [ ] `POST /databases/{id}/databases` (create database/schema/keyspace) where the engine
      allows it; honest NotImplemented elsewhere.
- [ ] Workspace-level "default target" (which mount a new database is created on) —
      stored as data, not app code (zero app code in grobase).

**G7 · Type fidelity + coercion contract** — gate m249
- [x] Postgres raw reads decode cells by type (`postgres/cell.rs`, 25213500). Before,
      `execute_raw` read every column as `serde_json::Value` (json/jsonb only) and
      `unwrap_or(Null)` hid the failure: a raw `SELECT id` returned null. Undecodable
      types now fail with the column name and a `::text` / `to_jsonb` cast hint.
      Unit-tested without a DB (`cargo test -p data-plane-pool postgres::cell`, 6 pass).
- [x] **G7a — grobase, no wire change** (f1cd7819). `NormalizedType` gains Binary, Time, Interval,
      Bigint (spelled so serde emits `"bigint"`, not `"big_int"`), Geometry, Vector.
      Every reverse-DDL mapper is an exhaustive match (`pg_sql_type`, `mysql_sql_type`,
      `sqlite_sql_type`, `ddl_bson_type`), so each new variant is a compile error
      until its arm exists. Normalizers still emit the old values. One coercion table
      engine→engine (lossless / lossy-with-reason / refused) as a pure library with
      an exhaustive test.
      Done: `data-plane-core::coercion` + the four reverse-DDL arms; geometry/vector
      refused in DDL (no SRID/dimension yet), interval only on pg.
- [x] **osionos learns the new strings first.** `liveSchemaMapper` today renders any
      unknown type as editable text, and `liveWriteClient`/`liveValueCodec` coerce PG
      ids as `integer`. Binary/geometry/vector/interval are read-only; bigint keeps
      string precision. Old readers have no `#[serde(other)]`, so emitting first breaks
      every descriptor they decode.
      Done in code (osionos f87752323, notion-database-sys 6c68e81f): binary/
      interval/geometry/vector read-only, bigint a number column whose pk filter and
      FK writes keep digits past 2^53 as strings, time edits as text.
- [x] **G7b — flip the emitters.** Normalizers map bytea/time/interval/int8/geometry/
      vector to the new variants; the MySQL (null on non-UTF-8) and SQLite (`blob:N
      bytes`) lossy codecs return `\x` hex; PG writes accept the new types instead of
      409. TS `SCHEMA_DDL_COLUMN_TYPES`, the JS SDK unions and the openapi list follow.
      Done: one `data-plane-core::binary` codec (`\x` hex, parse refuses `+1`); PG
      binds strings into INT8/NUMERIC/BYTEA/TIME; DDL accepts binary/time/interval/
      bigint, geometry/vector stay describe-only. Ships live only after the osionos
      reader above is live.
- [x] Conformance round-trips one value of each type per engine (m249).
      Live on the VM 2026-10-30 (7 mounts: cockroachdb, mariadb, mongodb, mssql, mysql,
      postgresql, sqlite): 51 PASS, 22 GAP, 0 FAIL. Every GAP names its reason in
      `m249-type-round-trip.mjs` `GAPS`, and a GAP that starts passing fails the gate.
- Open: Integer→`bigint` DDL (PG) and Integer→BSON `long` (Mongo) mean a
      create→describe round trip reads back `bigint`; vector and geometry carry no
      dimension / SRID yet; int8 reads past 2^53 still travel as JSON numbers, so JS
      rounds them (only written keys keep their digits); PG interval writes are not
      parsed (interval is read-only in osionos); BSON has no date-only type, so a
      Mongo `date` describes back as `datetime`. On MariaDB and Oracle MySQL the datetime
      bind is type-blind (an RFC 3339 string is refused, ERROR 1292) and a uuid column is
      CHAR(36), described as text. One ~70 s control-plane stall on the
      VM (2026-10-30 00:14–00:15 CET: data-plane forwards 502 at 5 s, then tenant-control
      503 at 8 s) failed two m249 runs; no container restarted, cause not found, and it
      did not recur in the next runs.

**G8 · Cross-engine data + schema migration** — gate m250
- [ ] Job API: source mount → target mount, schema translation via G7, data copy by
      cursor pages (adds `next_cursor`, `operation.rs:232`), resumable, quota-metered.
- [ ] Dry run returns the lossy-column report before anything is written.
- [ ] Bulk import/export routes on the data plane (beyond the 1000-row batch).

### Phase 4 — depth per engine

**G9 · Extended DDL** — gate m251
- [ ] Decide ONE DDL implementation (Rust `apply_schema_ddl` vs TS schema-service) and
      delete the other path's duplicate ops.
- [ ] Structured ops: create/drop index, unique/check constraint, FK (same mount), view,
      function, trigger — each a capability flag per engine, honest NotImplemented.
- [ ] `EXPLAIN` endpoint for SQL engines + Mongo `explain()`; slow-query view per mount.

**G10 · Transaction parity** — gate m252
- [ ] Mongo transactions on (replica set already live); SQLite transactions; MSSQL
      transactions; savepoints where the engine has them.

### Phase 5 — cross-engine relations and automations

**G11a · Events carry the mount** — gate m253 (after G1 enforce)
- [ ] Outbox payload gains `db_id`; triggers and webhooks gain `mounts[]` (empty = all),
      emitted by TS and Rust in lockstep with a parity test.
- [ ] Automation targets come only from the stored rule, never from row data
      (`outbox.service.ts:202-211` reads `target_engine` from writable columns).
- [ ] Route for the live automations client, so osionos stops calling a dead path.

**G11b · Cross-mount automation actions** — BLOCKED
- [ ] `write_mount`, `run_function` (scoped data client), run history + DLQ. Lifts when
      a tenant service principal exists and the G12 slice-2 decision is made.

**G12 · Relation contracts** — gate m254 · ADR 0008 — BLOCKED
- Lifts: G1 enforced with m243 green; the `tenant_databases.tenant_id` UUID ↔ contract
  slug mapping named and tested; O5 says whether cross-mount cascade is needed (if not,
  slice 1 only: registry, `sync_check`, orphan report).
- [ ] Contract registry table: source `mount.table.column` → target
      `mount.table.column`, cardinality, `on_delete` / `on_update`
      (restrict / cascade / set-null / none), consistency (`sync-check` / `eventual`).
- [ ] `ForeignKeyRef` gains an optional mount.
- [ ] Same-mount contract → real FK DDL (G9). Cross-mount → write-time existence check
      (sync) and cascade through G11 automations (eventual), with a reconcile job that
      reports orphans.
- [ ] Contract CRUD API with the same authz as DDL.

**G13 · Federated read** — gate m255 (last) — BLOCKED; exposure half moved to G0
- [ ] Trino behind auth + TLS, per-tenant catalogs generated from mounts, fixed Mongo
      catalog credentials; or an in-router join for small result sets. Planner
      `Federate` stays off until the gate is green.

## What this plan does not do

- It does not merge app databases: two apps' databases never merge
  (`service-boundaries`). Contracts relate mounts inside one tenant only.
- It does not promise distributed ACID across engines. Cross-mount writes are
  compensated (saga), not two-phase committed; the contract says which.
- It does not touch the VM's uncommitted operator edits, and no VM rollout happens
  without a confirmed window.
