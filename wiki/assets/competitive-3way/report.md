# binocle-one vs binocle-nano vs PocketBase — deep 3-way head-to-head

scripts/bench/METHOD.md + scripts/bench/nano-one-pb-load.sh (Phase G): one binary each FROM scratch, same box, oha at c=1/16/64, RSS sampled mid-load, 100k-row run + disk-after, boot-to-first-200. PocketBase pinned v0.39.3.

_Generated 2026-06-15T02:32:08.047Z_

## How to read

| source | style | meaning |
|---|---|---|
| measured | solid/filled | cites an artifact under `artifacts/` (our measurement) |
| published (pub) | hatched/dashed | vendor docs/pricing — the vendor's claim, **not** ours |
| modeled (model) | dotted | derived; states its formula |
| n/a | omitted | no honest number (e.g. Firebase has no self-host footprint) |

> SINGLE-NODE rows are apples-to-apples: three single-binary app backends, same box, same workload.  ·  MULTI-TENANCY IS NOT APPLES-TO-APPLES. PocketBase has NO native multi-tenancy (one app per process). binocle-nano/one are single-tenant-by-default SKUs built on the multi-tenant data plane — they GROW into the platform (the 10K/50K/100K density) on the same SDK; PocketBase cannot. So 'PocketBase at N tenants' is modeled as N instances (N x per-instance footprint) — see rss_vs_tenants.  ·  Single-node numbers are a FRESH run (nano-one-pb-load.json, 2026-06-15T02:27:26.661305Z, PocketBase v0.39.3, oha 8s/run, BIG_N=100000); the box is shared so absolute rps is indicative, ratios are the signal.

## 🏆 Scoreboard — who wins each index

**binocle-nano** wins **5 of 10** indexes — the overall winner.

| contender | indexes won |
|---|---|
| binocle-nano | 5 / 10 |
| binocle-one | 3 / 10 |
| pocketbase | 1 / 10 |
| binocle-platform | 1 / 10 |

## Single-metric comparisons

### idle_footprint_mib

resources · MiB — lower is better

![idle_footprint_mib](charts/idle_footprint_mib.svg)

**🏆 Winner: binocle-nano** — 2.01 MiB — 8.73% lower than runner-up vs binocle-one

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 2.01 | `artifacts/nano-vs-pocketbase.json` |
| binocle-one | measured | 2.2 | `wiki/nano-vs-pocketbase.md (m45: 6.41 MB / 2.2 MiB)` |
| pocketbase | measured | 13.1 | `artifacts/nano-vs-pocketbase.json` |

### binary_or_image_mb

resources · MB — lower is better

![binary_or_image_mb](charts/binary_or_image_mb.svg)

**🏆 Winner: binocle-nano** — 4.9 MB — 1.31× lower than runner-up vs binocle-one

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 4.9 | `artifacts/nano-vs-pocketbase.json` |
| binocle-one | measured | 6.41 | `wiki/nano-vs-pocketbase.md (m45)` |
| pocketbase | measured | 30.1 | `artifacts/nano-vs-pocketbase.json` |

### rss_under_load_mib

resources · MiB — lower is better

![rss_under_load_mib](charts/rss_under_load_mib.svg)

**🏆 Winner: binocle-nano** — 14.9 MiB — 1.25× lower than runner-up vs binocle-one

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 14.9 | `artifacts/nano-one-pb-load.json .rss_under_load` |
| binocle-one | measured | 18.6 | `artifacts/nano-one-pb-load.json .rss_under_load` |
| pocketbase | measured | 461.5 | `artifacts/nano-one-pb-load.json .rss_under_load` |

### disk_after_100k_mb

resources · MB — lower is better

![disk_after_100k_mb](charts/disk_after_100k_mb.svg)

**🏆 Winner: binocle-one** — 30.5 MB — 2.24% lower than runner-up vs binocle-nano

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 31.2 | `artifacts/nano-one-pb-load.json .disk_after_big` |
| binocle-one | measured | 30.5 | `artifacts/nano-one-pb-load.json .disk_after_big` |
| pocketbase | measured | 283.8 | `artifacts/nano-one-pb-load.json .disk_after_big` |

### cold_start_ms

ops · ms — lower is better

![cold_start_ms](charts/cold_start_ms.svg)

**🏆 Winner: binocle-one** — 5 ms — 1.2× lower than runner-up vs binocle-nano

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 6 | `artifacts/nano-one-pb-load.json .boot_ms` |
| binocle-one | measured | 5 | `artifacts/nano-one-pb-load.json .boot_ms` |
| pocketbase | measured | 131 | `artifacts/nano-one-pb-load.json .boot_ms` |

## Scale curves — y vs. tenant count

### Insert throughput vs concurrency (rps, higher better)

 · rps — x = tenant count (log scale)

![Insert throughput vs concurrency (rps, higher better)](charts/insert_rps_vs_concurrency.svg)

**🏆 Winner: binocle-nano** — 18,240 rps — higher than runner-up vs binocle-one

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 7,064, 17,197, 18,240 | `—` |
| binocle-one | measured | 7,040, 15,924, 17,869 | `—` |
| pocketbase | measured | 2,539, 3,408, 2,612 | `—` |

### Insert p99 tail vs concurrency (ms, lower better)

 · ms — x = tenant count (log scale)

![Insert p99 tail vs concurrency (ms, lower better)](charts/insert_p99_vs_concurrency.svg)

**🏆 Winner: binocle-nano** — 9.4 ms — lower than runner-up vs binocle-one

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 0.3, 5.6, 9.4 | `—` |
| binocle-one | measured | 0.3, 5.6, 9.4 | `—` |
| pocketbase | measured | 0.7, 82.9, 148 | `—` |

### List/read throughput vs concurrency (rps, higher better)

 · rps — x = tenant count (log scale)

![List/read throughput vs concurrency (rps, higher better)](charts/list_rps_vs_concurrency.svg)

**🏆 Winner: pocketbase** — 19,206 rps — 1.33× higher than runner-up vs binocle-one

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 6,659, 11,637, 14,020 | `—` |
| binocle-one | measured | 6,386, 11,530, 14,399 | `—` |
| pocketbase | measured | 2,905, 25,544, 19,206 | `—` |

### List/read p99 tail vs concurrency (ms, lower better)

 · ms — x = tenant count (log scale)

![List/read p99 tail vs concurrency (ms, lower better)](charts/list_p99_vs_concurrency.svg)

**🏆 Winner: binocle-one** — 7.6 ms — lower than runner-up vs binocle-nano

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-nano | measured | 0.3, 2, 7.8 | `—` |
| binocle-one | measured | 0.3, 2, 7.6 | `—` |
| pocketbase | measured | 0.8, 2.6, 27.3 | `—` |

### RAM to HOST N tenants (MiB, lower better) — the multi-tenancy reality

 · MiB — x = tenant count (log scale)

![RAM to HOST N tenants (MiB, lower better) — the multi-tenancy reality](charts/rss_vs_tenants.svg)

**🏆 Winner: binocle-platform** — 3 MiB _(modeled)_ — 437,000× lower than runner-up vs pocketbase-n-instances

| contender | source | value | artifact / origin |
|---|---|---|---|
| binocle-platform | measured | 2.6, 3, 3 | `artifacts/scale/footprint-live-24887.json` |
| pocketbase-n-instances | modeled | 131,100, 655,500, 1,311,000 | `10,000 x 13.11 MiB per-instance idle RSS = 128 GiB. PocketBase is one app per process; N tenants = N processes.` |

