# Benchmark methodology — the rules every number on this product follows

Every public claim ("8 ms/req", "serves N tenants", "6× lighter than PocketBase") must cite an
artifact produced under these rules. A number without an artifact is marketing; we don't ship those.

## The rules

1. **Same box, solo stack.** All comparative runs happen on one machine, sequentially — never two
   stacks at once (the Supabase head-to-head boots their stack only after `make down -v` of ours).
   Every artifact embeds an `env` block: nproc, MemTotal, kernel, git SHA, generated-at.
2. **Pinned everything.** Competitor images/binaries pinned to an exact tag (PocketBase v0.39.3,
   supabase/docker at a pinned tag, grafana/k6 pinned). Upgrades are a new artifact, never an edit.
3. **Warmup excluded.** 30 s of traffic before measurement starts (caches warm: verify ~30 s TTL,
   mount resolve, engine pools). Cold-path numbers are reported separately and labeled cold.
4. **N=3 runs, median reported, all runs kept.** The artifact stores every run; headline numbers are
   the median run (by achieved RPS for load; by p95 for latency-only probes). Never bare averages.
5. **Percentiles, not means.** p50 / p95 / p99 + sustained RPS + error rate. A run with error rate
   > 1% is a FAILED run, not a slower one.
6. **Rate limits.** Tier-mask token buckets fire 429s by design. Load runs at the tier's advertised
   rps must show 0 limiter rejections; capacity runs (limits lifted) must either use an unmasked
   tenant (`PACKAGE_ENFORCEMENT=0` stack) or detect and report `limit_hit: tier_rps` when the 429
   wall, not latency, is the ceiling.
7. **Artifacts are JSON, versioned by date, never overwritten in place.** `artifacts/bench/` is
   git-untracked (it can carry scratch API keys); baselines are copied to
   `artifacts/bench/baseline-<YYYY-MM>/` and treated as immutable.
8. **Budgets live in one file.** `scripts/bench/budgets.json` is the single numeric source for gate
   bars (m32 RAM budgets, m38 latency/error thresholds, m39 scale targets). Docs and the marketing
   site cite artifacts; gates read budgets. Numbers never live in two places.

## The canonical workload (CRUD mix)

The unit of comparison across tiers, engines, architectures (pre/post-R1) and competitors:

| share | operation | shape |
|---|---|---|
| 70% | list | `op:list, limit 30, filter on an indexed column` |
| 20% | insert | single row, 4 columns |
| 5%  | update | by primary key |
| 5%  | delete | by primary key (rows replenished by the inserts) |

Separate scenarios: `aggregate` (count + sum group-by) and `batch` (10-item atomic batch).
Table shape: `bench_items(id text pk, name text, grp text, val int)` seeded with 500 rows.

### Per-API equivalence map (the Supabase comparison is attack-proof or it is nothing)

| logical op | grobase | supabase |
|---|---|---|
| list 30 filtered | Kong `/data/v1/query` op:list filter `grp eq g3` limit 30 | PostgREST `GET /rest/v1/bench_items?grp=eq.g3&limit=30` |
| insert | op:insert | `POST /rest/v1/bench_items` |
| update by pk | op:update | `PATCH /rest/v1/bench_items?id=eq.<id>` |
| delete by pk | op:delete | `DELETE /rest/v1/bench_items?id=eq.<id>` |
| auth'd identity | `X-Baas-Api-Key` (Argon2id-verified, 30s cache) | `apikey` + JWT `Authorization` |
| aggregate | op:aggregate count/sum | PostgREST `select=grp,count:id.count()` group |

Both sides traverse their gateway (our Kong, their Kong) — no shortcutting either side. Latency is
reported auth-included AND auth-excluded (the identity layers differ structurally).

## How to run

```bash
make bench-load PACKAGE=pro WORKLOAD=crud MODE=short   # 3×60s, artifact + table
make bench-load PACKAGE=pro WORKLOAD=crud MODE=full    # 3×300s
make bench-capacity PACKAGE=pro                         # ramp to the wall, limits lifted
make bench-mem PACKAGE=essential DURATION=30m           # RSS drift under sustained load
bash scripts/bench/realtime-fanout.sh                   # fan-out matrix
bash scripts/bench/grobase-vs-supabase.sh               # head-to-head (solo, on-demand)
```

Gates: `make verify-m38` (load smoke vs budgets), `make verify-m39` (scale smoke; SCALE=10000 for
the full validation). Neither runs heavy modes inside `verify-all`.
