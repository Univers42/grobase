# Docker self-build & slim footprint (42-Inception)

**Status: shipped + parity-proven.** Every service in the active stack now builds
from a base **we control** (alpine / debian-slim / scratch / distroless / temurin)
plus a downloaded release **binary** or official **package** — there is no
third-party *fat application image* used as a `FROM` base anywhere in the active
stack. The green CI stayed green across the cutover (the parity gate): run
`27635612970` — **47 jobs, all success, 0 failed / 0 skipped / 0 cancelled** —
covering integration (slim kong/gotrue/mongo boot + 12 phases), all 24 self-built
infra builds, cloud + enterprise gates, offers, SDKs, and unit tests.

## Why

Pulled vendor images are fat (mssql ~1.67 GB, trino ~1.49 GB, mongo ~874 MB) and
outside our control. The 42 discipline: own the `FROM`, install the software
ourselves on the slimmest base each runtime allows, keep every plane/profile
modular and the runtime contract byte-identical (verified by CI).

**Allowed:** alpine / debian-slim / distroless / temurin / language-builder /
scratch bases; downloading an upstream **static release binary** or official
**.deb/apt package** (a binary/package is not a ready-made image).
**Forbidden:** `FROM <vendor>/<app>:<tag>` (kong:3.8, mongo:7, supabase/gotrue, …).

**Reproduce any row:** from `mini-baas-infra/`, `docker compose build <service>`
then `docker images mini-baas-infra-<service> --format '{{.Size}}'`; or the
per-service CI job `Build (infra) <service>` in `infra-build`.

## Per-service image size (self-built vs the fat image it replaced)

| Service | Replaced (baseline) | Self-built base | Slim size | Δ |
|---|---|---|---|---|
| mongo-keyfile | mongo:7 — 874 MB | alpine + openssl | **10.7 MB** | **−863 MB** |
| db-bootstrap | pgvector/pgvector:pg16 — 438 MB | alpine + pg-client | **12.9 MB** | **−425 MB** |
| mongo-init | mongo:7 — 874 MB | debian-slim + mongosh | **281 MB** | **−593 MB** |
| mysql | mysql:8.4 — 812 MB | alpine + mariadb | **242 MB** | **−570 MB** |
| mongo | mongo:7 — 874 MB | debian-slim + mongodb-org | **589 MB** | **−285 MB** |
| debezium | quay.io/debezium/server:3.0 — 1.06 GB | temurin-alpine JRE + tarball | **742 MB** | **−318 MB** |
| trino | trinodb/trino:467 — 1.49 GB | temurin-alpine JRE + tarball | **1.27 GB** | **−220 MB** |
| cockroach | cockroachdb/cockroach:v24.3.5 — 448 MB | static binary → slim | **~291 MB** | **−35 %** |
| prometheus | prom/prometheus:v2.52.0 — 272 MB | static binary → slim | **~147 MB** | **−46 %** |
| iceberg-rest | apache/iceberg-rest-fixture:1.8.1 — 512 MB | temurin gradle source build | **369 MB** | **−143 MB** |
| promtail | grafana/promtail:3.0.0 — 202 MB | static binary → slim | **~105 MB** | **−48 %** |
| mssql | mcr.microsoft.com/mssql/server:2022 — 1.67 GB | ubuntu + MS apt | **1.57 GB** | **−100 MB** |
| mariadb | mariadb:11 — 329 MB | alpine + mariadb | **242 MB** | **−87 MB** |
| supavisor | supabase/supavisor:2.7.4 — ~100 MB | elixir release → alpine | **47.8 MB** | **−52 %** |
| minio | minio/minio — 177 MB | static binary → slim | **~124 MB** | **−30 %** |
| redis | redis:7-alpine — 39 MB | alpine + apk redis | **11.5 MB** | **−27 MB** |
| kong | kong:3.8 — 376 MB | debian-slim + official .deb | **361 MB** | **−15 MB** |
| gotrue | supabase/gotrue:v2.188.1 — 52.5 MB | Go source → alpine | **51.9 MB** | flat |
| pg-meta | supabase/postgres-meta:v0.91.0 — 386 MB | node:20-slim source build | **384 MB** | flat |
| postgrest | postgrest/postgrest:v12.2.3 — 17.3 MB | scratch + static binary | **18.3 MB** | +1 MB |
| postgres | postgres:16-alpine — 276 MB | alpine + pg_net + **pgvector** | **279 MB** | +3 MB ¹ |
| mc | minio/mc | static binary → slim | **38.5 MB** | self-built |
| grafana | grafana/grafana:10.4.2 — 429 MB | self-built | **~429 MB** | flat ² |
| loki | grafana/loki:3.0.0 — 80 MB | self-built | **~80 MB** | flat ² |
| studio | supabase/studio — ~300 MB | node:22-slim next build | **762 MB** | +462 MB ³ |

¹ postgres grew ~3 MB to ship the `vector` extension — which is exactly what lets
**db-bootstrap drop 425 MB** (the extension lives in the engine, not the bootstrap
client). Net of the pair: **−422 MB**.
² grafana/loki are single large static Go binaries already; self-building on a slim
base reproduces ~the same size. The win is control, not bytes.
³ studio is the one honest regression: Next.js `.next/standalone` (363 MB) + static
(152 MB) + a glibc-only bundled `sharp` native module force a glibc runtime. It
builds and boots (HTTP 200), is `studio`-profile-only and optional, and is still
**our** image.

## Headline

- **17 of 24 shrank.** Biggest wins: sidecar/init containers that no longer carry a
  whole DB engine (mongo-keyfile −863 MB, mongo-init −593 MB, db-bootstrap
  −425 MB) and the SQL engines (mysql −70 %).
- **3 flat** (gotrue, pg-meta, grafana/loki — already minimal upstream), **2 ~flat**
  (postgrest +1, postgres +3 for pgvector), **1 honest regression** (studio).
- **Point is control + parity, measured.** Every cutover kept the green CI green;
  each image is reproducible from our Dockerfile on a base we own. The only
  remaining pull is `dlesieur/realtime-agnostic` — our own published Rust artifact
  (CI cannot reach its submodule to build it; it is already `Dockerfile.nano` →
  scratch).

## Technique by runtime (the reusable patterns)

| Runtime | Technique | Final base | Services |
|---|---|---|---|
| Rust | static-musl → scratch | scratch | data-plane-router (`Dockerfile.nano`) |
| Go (source) | builder → distroless/static | distroless | adapter-registry, gotrue |
| Go (static release binary) | copy upstream binary → slim | alpine/scratch | minio, mc, cockroach, prometheus, loki, promtail, grafana |
| Haskell | copy static-musl binary → scratch | scratch | postgrest |
| C via apk | `apk add` on alpine | alpine | redis, mysql, mariadb |
| Node | node:slim multi-stage + `npm/pnpm prune` | node:slim | pg-meta, studio (+ app services) |
| Elixir/BEAM | `mix release` → alpine + ncurses/libstdc++ | alpine | supavisor |
| JVM | temurin JRE + app tarball / gradle | temurin-alpine | trino, debezium, iceberg-rest |
| glibc-only (musl-incompatible) | official .deb / apt on debian-slim/ubuntu | debian-slim/ubuntu | kong, mongo, mongo-init, mssql |
| Postgres + C extensions | apk + source-build pg_net/pgvector | alpine | postgres, db-bootstrap |

## CI parity coverage

- `docker-build` (6) — the app/Go/Rust services integration consumes; integration
  `needs:` it.
- `infra-build` (24) — every self-built infra service compiles in isolation (one
  runner each, `fail-fast: false`), with a disk-reclaim step for the heavy
  JVM/SQL/Next builds. **Nothing depends on this job**, so a heavy-build failure is
  a real, *isolated* red — it can never cascade into skipping integration/gates.
- `integration-tests` — boots the slim default stack + mongo and runs phases
  1–8/10/14–16 + m102, proving the slim gateway/auth/CRUD/document-DB behave.

## Known residuals (outside the active CI-verified stack)

- `docker/services/postgres-graphql/Dockerfile` still bases on `postgres:16-bookworm`
  (the `pg_graphql` Rust/pgrx extension is risky to move to musl). Only exercised by
  `scripts/verify/m59-graphql-live.sh`, not the editions/CI. Follow-up: slim behind
  that gate.
- `docker-compose.track-binocle.yml` (legacy monorepo bridge, unreferenced by the
  Makefile/editions/CI) still pins kong/gotrue/postgrest/pg-meta/supavisor to fat
  images. The self-built Dockerfiles already exist; cutting it over is a zero-risk
  follow-up once it's confirmed still in use.
- `pg-backup` already builds on `debian:bookworm-slim` (compliant); `playground` /
  `stripe-mock` have no Dockerfile (inline alpine — compliant).
