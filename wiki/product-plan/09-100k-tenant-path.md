# 09 — The path to 10,000 and 100,000 tenants

> Companion to [`../grobase-master-plan.md`](../go-to-market/grobase-master-plan.md). Every limit below is
> traced to code or a benchmark artifact. The question this answers: **how many tenants can one
> Grobase deployment hold, and what has to change to hold more?**

## The per-tenant footprint (measured / code-traced)

| Resource | Per tenant | At 10K | At 100K | Bottleneck? |
|---|---|---|---|---|
| `tenants` / `tenant_api_keys` / `tenant_databases` rows | a few rows | trivial | trivial (Postgres does millions) | no |
| **Engine pool** (one per `pool_key`) | **1 pool / mount** | **10K pools** | **100K pools** | **YES — #1** |
| Postgres connections | pool × `max_conn` | 10K–50K conns | 100K–500K | YES (follows pools) |
| Token bucket (`ratelimit.rs`) | ~24 B | 240 KB | 2.4 MB | no (RAM); yes (multi-instance) |
| verify + mount cache entry | ~1 KB, 30 s TTL | ~10 MB | ~100 MB | only at extreme key churn |
| Realtime subscription | ~150 B, global registry | 1.5 MB / 1M subs | 15 MB / 10M subs | YES at high sub counts |
| Kong | 3 shared consumers, tenant-agnostic | — | — | no |

The new `/metrics` counters (`baas_data_plane_pools_open`, `..._pool_events_total{event}`,
`..._cache_events_total`, `..._ratelimit_tracked`) make every row above observable live.

## The #1 bottleneck: one pool per tenant, even when they share a database

`DatabaseMount::pool_key()` (mount.rs:59) is
`tenant_id / project_id / mount_id / engine / cred_version`. **The tenant id is in the key**, so
two `shared_rls` tenants pointing at the *same* physical Postgres still get *two separate pools* —
each opening its own connections to the same database. The registry LRU-caps at
`DATA_PLANE_MAX_POOLS` (default **256**, `config.rs`), so a 10K-tenant fleet thrashes: 10K
distinct keys ≫ 256 → constant evict/reopen churn (now visible as
`pool_events_total{event="evicted"}` climbing at steady state).

And a single pool saturates at **~400 rps of reads** before a connection cliff (p99 → 10 s,
`capacity-essential.json`). So the per-tenant pool model fails two ways at scale: too many pools,
and each pool is a hard 400-rps wall.

### The fix that unlocks 100K: key shared pools by DSN, scope per request

For `shared_rls` and `schema_per_tenant` mounts (which share a connection target), the pool should
be keyed by the **DSN / connection target**, not the tenant — with tenant identity applied
per-request at checkout (`SET app.current_tenant` for RLS, `SET search_path` for schema-per-tenant,
both already implemented in `isolation.rs`). That collapses **N-tenant pools → 1 pool per DSN**:
10K shared_rls tenants on one Postgres become **1 pool**, not 10K. Only `db_per_tenant` /
`tenant_owned` (genuinely distinct DSNs) keep a pool each — which is correct, because those are the
isolation models you *pay* for hard walls.

This is the single highest-leverage scale change. It is staged:

1. **10K today** (validated path): keep per-tenant pools, but size `DATA_PLANE_MAX_POOLS` per tier
   (hypotheses 64/256/1024/4096 — B4 finalizes from the churn curve) and put `shared_rls` mounts
   behind **supavisor** (already in compose, unused) for connection multiplexing, so 10K pools map
   to a bounded connection count. `docker-compose.scale.yml` raises PG `max_connections` for the
   experiment. Acceptance: `make verify-m39 SCALE=10000` — p99 ≤ 2× baseline, 0×5xx, RSS ≤ 512 MiB.
2. **100K**: DSN-keyed shared pools (above) so pool count tracks *databases*, not tenants; plus the
   levers below.

## The other limits, and what each needs at 100K

| Limit | At 10K | At 100K | The change |
|---|---|---|---|
| **Rate limiter** | in-process buckets fine (2.4 MB) | **breaks across replicas** — each instance allows N× the rate, resets on restart | `DATA_PLANE_RATELIMIT_BACKEND=redis` (Lua token bucket); in-process stays the single-node fast path (B4) |
| **schema_per_tenant** | ~16K schemas/instance is the practical ceiling | **not feasible** on one instance | shard Postgres, or use `shared_rls` (RLS rows, no schema overhead) at this density |
| **Realtime** | 1M subs ≈ 1.5 MB, global registry ok | 10M subs ≈ 15 MB + O(P) lookup per event | **tenant-partition** the subscription registry (tenant-tag + per-tenant index — staged in B4); shard the realtime plane across nodes |
| **Key verify (Argon2id) — the MEASURED #1 ceiling** | at 1K tenants, fan-out drops the verify-cache to ~10% hit → Argon2 @ 2-concurrent = ~40 verify/s wall → **502s** (`multitenant-1000.json`) | same wall, sooner | enlarge+lengthen the verify cache (more keys warm); **scale stateless tenant-control replicas** (N× throughput); Argon2 only on first-seen + a cheap keyed-hash check on the warm path. The data plane itself stayed at 51 MiB / 38 pools serving 1K tenants — it is NOT the limit |
| **Control-plane crypto** | bounded (shipped: Argon2/scrypt semaphores) | same bound holds; add replicas for throughput | provisioning is ~13/s/instance; run K replicas for K× provisioning |
| **Postgres connections** | raise `max_connections` (scale compose) | DSN-keyed pools + supavisor make this track *databases*, not tenants | the DSN-pool fix is what makes 500K connections unnecessary |

## The honest bottom line

- **10K tenants on one deployment: reachable today** with pool sizing + supavisor + `shared_rls`,
  validated by `make verify-m39 SCALE=10000`. The control-plane OOM that used to break bulk
  provisioning is fixed (Argon2/scrypt concurrency bounds).
- **100K tenants: one architectural change does most of the work** — DSN-keyed shared pools so the
  pool count tracks databases, not tenants — plus a Redis-backed limiter, realtime partitioning,
  and stateless control-plane replicas. None of these is a rewrite; each is a bounded change on the
  measured chassis, and each has a metric (the new `/metrics` counters) to prove it landed.
