# C1 — Supavisor connection pooler (opt-in) + pooled-vs-direct parity

Overlay: [`../../docker-compose.pooler.yml`](../../docker-compose.pooler.yml).
**Opt-in only — never a default.** The base stack stays byte-parity; nothing in
`docker-compose.yml` changes.

## What it wires

```
data-plane-router-rust ──(system/outbox DSN)──► supavisor:6543 (txn mode) ──► postgres:5432
                          per-tenant mounts ────────────────────────────────► (unchanged: DSN from adapter-registry)
```

- Brings the base **Supavisor stub** up with a full transaction-mode config.
- Sets two data-plane env vars — the **C1 wiring seam**:
  - `DATA_PLANE_POOLER_URL` → `postgres://…@supavisor:6543/…` (the pooled system DSN)
  - `DATA_PLANE_STATEMENT_CACHE=off` → tells the data plane to stop client-side
    prepared-statement caching, **required** under a transaction-mode pooler
    (prepared statements are not preserved across pooled checkouts).
- Adds `depends_on: supavisor (service_healthy)` so the data plane waits.

> **Status (C1 LIVE):** the Rust PG adapter now **consumes** both vars
> (`crates/data-plane-pool/src/postgres.rs` — `pooler_url()` /
> `statement_cache_off()` / `repoint_dsn_host()`, wired in `open_pool`). When
> `DATA_PLANE_POOLER_URL` is set, the adapter repoints the resolved DSN's
> host:port to the pooler endpoint (db/user/password/sslmode preserved) and dials
> the pooler instead of the direct DSN; `DATA_PLANE_STATEMENT_CACHE=off` recycles
> each pooled connection with `RecyclingMethod::Clean` (`DISCARD TEMP/SEQUENCES`,
> NOT `DEALLOCATE ALL` — txn-mode-safe). **Both UNSET (the default) → the EXACT
> direct path, byte-parity.** Proven by `scripts/verify/m98-pooler-parity.sh`
> (pooled CRUD row-for-row identical to direct; cross-owner RLS GUC survives the
> txn-mode pooled checkout). The overlay above wires the **Supavisor** flavour;
> the gate proves the same invariant with **pgbouncer** (a lighter throwaway
> transaction-mode pooler) — both are transaction-mode poolers, the only property
> that matters for the seam.

## Run

```bash
cd apps/baas/mini-baas-infra

# Direct baseline (no overlay) — the default stack.
make up PACKAGE=essential

# Pooled (opt-in) — bring postgres, supavisor, and the data plane up together.
docker compose -f docker-compose.yml -f docker-compose.pooler.yml \
    up -d postgres supavisor data-plane-router-rust

# Confirm supavisor is healthy + the seam env landed.
docker inspect mini-baas-supavisor --format '{{.State.Health.Status}}'
docker inspect mini-baas-data-plane-router-rust \
    --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'POOLER_URL|STATEMENT_CACHE'

# Tear down: re-up WITHOUT the overlay → back to direct, byte-parity.
docker compose -f docker-compose.yml up -d data-plane-router-rust
```

## Pooled-vs-direct PARITY expectation

A connection pooler is a **transport optimization, not a semantic one**. The
contract: **for every request, pooled and direct return byte-identical bodies +
status codes.** A pooler changes *how* connections are reused, never *what* a
query returns. Concretely:

| Property | Direct | Pooled (txn mode) | Parity expectation |
|---|---|---|---|
| Response body / status | baseline | — | **byte-identical** (the gate) |
| Isolation (RLS / owner-scope) | per-request `apply_rls_context` | same — re-stamped per checkout | **identical** (pooling holds no tenant state, same reason SHARE_POOLS is neutral — see `wiki/scale-slo.md` §1) |
| Prepared statements | client-cached | **disabled** (`STATEMENT_CACHE=off`) | identical results; first-call latency may rise slightly (no plan reuse) |
| Connection count to PG | 1 per data-plane pool | bounded by `POOLER_DEFAULT_POOL_SIZE` | pooled holds PG conns ≤ direct under fan-out (the *point* of C1) |
| `SET`/session GUCs across statements | same backend | **not guaranteed** across txn-mode checkouts | the data plane already stamps GUCs **per request inside one txn**, so this is safe; any cross-request session state would NOT be (none exists today) |

**The honest caveat that makes txn-mode safe here:** isolation is applied
*inside each request's transaction* (`apply_rls_context` runs at the top of the
request), so a transaction-mode pooler — which can hand a different backend to
the next request — never leaks tenant state. This is the **same invariant** that
lets 24,887 tenants share one pool (`wiki/scale-slo.md`). If a future change
ever moves isolation to a *session*-level `SET` outside the request txn, txn-mode
pooling would break it — that is the one thing the parity gate must guard.

## Parity gate — C1 (AUTHORED + GREEN)

`scripts/verify/m98-pooler-parity.sh` (throwaway containers only — fully
locally-runnable): builds the data-plane-router FROM CURRENT source, boots a
scratch postgres + pgbouncer (transaction mode) on a private `$$`-suffixed
network, then runs the SAME CRUD set (list/get/aggregate) against a **direct**
router (`DATA_PLANE_POOLER_URL` unset) and a **pooled** router
(`DATA_PLANE_POOLER_URL`→pgbouncer + `DATA_PLANE_STATEMENT_CACHE=off`), and
asserts three arms:
- **POSITIVE** — `diff` of the normalized pooled vs direct responses is EMPTY
  (row-for-row byte-parity: a pooler is a transport optimization, not a semantic
  one).
- **REJECT (load-bearing)** — through the pooled router, owner B sees ONLY its own
  row and back-to-back A→B→A each sees only its own rows: the per-request RLS GUC
  (`app.current_user_id`) SURVIVES the transaction-mode pooled checkout (the one
  invariant a txn-mode pooler could break). RLS is real here — a FORCE'd policy +
  a non-superuser role, so the policy actually bites.
- **PARITY** — `DATA_PLANE_POOLER_URL` unset → the direct path is the baseline the
  POSITIVE arm diffs against (flag-OFF = byte-identical).

An EXIT trap removes every container/network/image; it never touches a
`mini-baas-*` container or the live `docker-compose.yml`.
