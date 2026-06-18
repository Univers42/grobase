# Fast first build — pull prebuilt images instead of compiling

Self-building every service (42-Inception) made the images small and ours, but a
fresh clone then **compiles everything from source** for its edition (Rust
data-plane, Go control-plane, gotrue, postgres+pg_net+pgvector, the JVM analytics
images, …) — minutes of work. To get the slimming *and* a fast first start, CI
publishes each heavy image to GHCR so you can **pull** the prebuilt layers.

## TL;DR

```bash
# from mini-baas-infra/
make pull EDITION=query     # fetch prebuilt heavy images from GHCR (~30–60 s)
make up   EDITION=query     # start; only the lightweight Node/Go apps build (seconds)
```

vs. the from-source path (no network for images, fully reproducible, slower):

```bash
make build EDITION=query    # compile every service from source (minutes)
make up    EDITION=query
```

Both produce the same running stack — `make pull` just skips the expensive
compiles. `make up` after `make pull` builds only the services that weren't
published (the fast Node/Go app layer); the slow builds are already local.

## What's published

On every push to `main`, the `infra-build` CI job builds **our own Dockerfiles**
and pushes the result to:

```
ghcr.io/univers42/grobase-<service>:latest          # moving tag, tracks main
ghcr.io/univers42/grobase-<service>:sha-<commit>     # immutable, pin for reproducibility
```

Published services (the heavy / slow builds):

- **engines & data:** postgres, mongo, mongo-init, mongo-keyfile, mysql, mariadb,
  cockroach, mssql, redis
- **gateway / auth / api:** kong, gotrue, postgrest, db-bootstrap, pg-meta, supavisor
- **data plane:** data-plane-router (Rust)
- **analytics / storage:** trino, debezium, iceberg-rest, minio, mc, studio
- **observability:** prometheus, grafana, loki, promtail

The lightweight NestJS app services (query-router, permission-engine, …) and the
Go control-plane services (orchestrator, tenant-control, …) build in seconds, so
they are intentionally **not** published — `make up` builds them locally.

This is still 42-compliant: every published image is *our* Dockerfile's build
artifact (the same model as `dlesieur/realtime-agnostic`), never a third-party
fat application image.

## Visibility — private by default

The packages are created **private** (only you / authenticated CI can pull). For
your own machines, authenticate once:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <your-gh-username> --password-stdin
make pull EDITION=query
```

To let **anyone** self-host by pulling anonymously (the OSS path), flip each
package to public — once, in the GitHub UI:

> github.com → your profile → **Packages** → `grobase-<service>` → *Package
> settings* → **Change visibility** → Public

(or set the owner's default package visibility to public). Public packages need
no `docker login` to pull. Visibility is reversible at any time.

## Reproducibility note

CI integration tests always `--build` the current commit's Dockerfiles (never the
published `:latest`), so the published image and the source can never silently
diverge: a green run means the published `:latest` *is* this commit's build. Pin
`:sha-<commit>` when you need a byte-exact image for a specific revision.
