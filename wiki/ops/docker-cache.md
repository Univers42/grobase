# Docker cache hygiene — why it grows, and the guardrails

A full clone that builds the stack accumulates **two** unbounded Docker cache pools.
On one dev box they reached **~92 GB build cache + ~84 GB cache volumes** before anyone
noticed. This is the runbook to cap both — **without ever touching the real data volumes**.

## Why it grows (the diagnosis)

The Dockerfiles are actually well-built (manifest-first dependency layering, stable
`cargo-registry`/`cargo-git` cache-mount IDs, `.dockerignore` present). The bloat is
structural, not a bug:

1. **No GC ceiling by default.** BuildKit cache mounts (`RUN --mount=type=cache,…`) are
   *persistent by design* and are never evicted on their own. Without a configured limit
   the daemon keeps cache up to a high default ceiling → it grows until the disk fills.
   **Yes, it accumulates over time** — every build of a changed layer adds entries.
2. **Per-shape cache multiplication.** The build matrix gives each shape its own multi-GB
   Rust `target` cache: `dpr-target` (release, 8 engines), `dpr-target-nano`,
   `dpr-target-one`, the realtime workspace target, plus Go build/mod caches and
   `node_modules`. Each is GBs; nothing evicts them.
3. **Two cache systems.** Rust/Go compile **two ways** — `docker build` (BuildKit
   `type=cache` → counted as *Build Cache*) **and** the Makefile's
   `docker run -v <vol>:/work/target cargo build` (named volumes → counted as *Local
   Volumes*). Both grow; the daemon GC only governs the first.

## The guardrails

### 1. Cap the BuildKit build cache — `daemon.json` GC

`/etc/docker/daemon.json` (Engine 28+/BuildKit ≥0.16 — note the field names: the older
`defaultKeepStorage`/`keepStorage` are **deprecated and silently ignored**, you must use
`reservedSpace`/`maxUsedSpace`/`minFreeSpace`):

```json
{
  "registry-mirrors": ["https://mirror.gcr.io"],
  "data-root": "/mnt/storage/docker",
  "builder": {
    "gc": {
      "enabled": true,
      "policy": [
        { "filter": ["unused-for=168h"], "maxUsedSpace": "8GB" },
        { "all": true, "reservedSpace": "10GB", "maxUsedSpace": "25GB" }
      ]
    }
  }
}
```

- `reservedSpace` = floor BuildKit keeps for build speed. `maxUsedSpace` = the hard ceiling.
- `unused-for=168h` renders as `Keep Duration: 168h` in `buildx inspect`.

Apply (⚠️ the restart stops every container; data volumes are untouched):

```sh
jq empty /etc/docker/daemon.json && echo "JSON OK"   # NEVER restart on invalid JSON
sudo systemctl restart docker
```

Verify it **took** (not the default policy):

```sh
docker buildx inspect default
# EXPECT a rule with `Max Used Space: 25GiB` and a rule whose Keep Duration is 168h.
# If you instead see Filters `type==source.local,type==exec.cachemount,…` with no
# Max Used Space, the config did NOT apply (stale field names) — re-check the keys above.
```

### 2. Cap the named volume caches + belt-and-suspenders — `make docker-gc`

The daemon GC does **not** see the named volume caches (the `docker run -v` pool). This
target trims them, plus a version-stable build-cache prune. It uses an **explicit
cache-name allowlist**, so it can never match a `*-data` volume — safe to run any time
(unlike `docker volume prune`, which deletes "unused" volumes = your data when the stack
is down).

```
make docker-gc        # defined in orchestrators/makes/80-ops.mk
```

Verify:

```sh
make help | grep docker-gc     # listed → wired into the help generator
make -n docker-gc              # dry-run: prints commands, runs nothing
make docker-gc                 # runs; ends with `docker system df` showing the trim
```

### 3. Run it weekly — cron

`crontab -e` (your **user** crontab — you're in the `docker` group, so no sudo):

```cron
SHELL=/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin
# weekly docker cache GC — Sundays 03:00
0 3 * * 0 cd /ABSOLUTE/PATH/TO/grobase && make docker-gc >> /tmp/docker-gc.log 2>&1
```

The `PATH` line matters — cron runs with a stripped environment and won't find
`make`/`docker` otherwise. Verify, then prove it works under cron's env without waiting a
week:

```sh
crontab -l | grep docker-gc
env -i SHELL=/bin/sh PATH=/usr/local/bin:/usr/bin:/bin HOME="$HOME" \
  sh -c 'cd /ABSOLUTE/PATH/TO/grobase && make docker-gc'   # simulates cron's environment
```

`env -i` catches the two classic cron failures — missing `PATH` and missing `HOME` (the
docker CLI reads `~/.docker/config.json`).

## Full reset (keep real data, drop everything rebuildable)

When you want to reclaim *everything* at once (images + build cache + cache volumes),
keeping only the real data:

```sh
PROTECT='postgres-data|redis-data|vault-data|mysql-data|mariadb-data|mongo-data|mongodb_data|mssql-data|cockroach-data|minio-data|functions-data|grafana-data|loki-data|prometheus-data|mongo-keyfile|gw-one-data'
docker rm -f $(docker ps -aq)                                  # stop+remove containers (NOT `down -v`)
docker rmi -f $(docker images -aq)                             # all images
docker builder prune -af                                       # all build cache
docker volume ls --format '{{.Name}}' | grep -Ev "$PROTECT" | xargs -r docker volume rm   # caches + anonymous junk
docker system df
```

**Never** use `docker volume prune` / `docker system prune --volumes` here — with the
stack down, your data volumes count as "unused" and would be deleted. The
`grep -Ev "$PROTECT"` substitute can only ever hit caches.

Verify data survived: `docker volume ls -q | grep -Ec "$PROTECT"` → **20**.

## Deeper optimization (reduces how fast you refill)

- **Stop double-caching:** route compiles through either the Dockerfiles (BuildKit, now
  GC-capped) *or* the `docker run -v` volumes — not both.
- **Merge redundant target IDs:** shapes that share a cargo profile should share a cache
  `id=` instead of `dpr-target-nano` vs `dpr-target-one`.
- **CI → registry cache:** `cache-from/to: type=gha,mode=max` so CI runners don't grow
  local cache.
