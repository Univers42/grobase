# RELEASE — how a Grobase BaaS version ships

Maintainer doc. The release pipeline it was written around,
`.github/workflows/baas-release.yml`, belonged to the Track-Binocle monorepo and
**does not exist in this repo** (`.github/workflows/` holds `ci.yml`,
`mini-baas-security.yml` and `nightly-proof.yml`; `HUMAN-ATOMS.md` §2 records the
same). Sections that describe that pipeline are marked as monorepo history; the
rest are the steps that work here.

## Versioning

- **One umbrella version** for the suite: the 16 bake images + binocle-nano/one
  images and binaries all carry the same `X.Y.Z`.
- **Release images go to Docker Hub** (monorepo decision 2026-06-13): versioned
  images live under `docker.io/dlesieur/*` (the `REGISTRY` default in
  `docker-bake.hcl`) — public by default on push, no registry-visibility step.
  The buildx layer cache rides GHCR. Binary tarballs + install.sh were GitHub
  Release assets of the monorepo; none are published from this repo.
- **Per-commit images go to GHCR from this repo**: `.github/workflows/ci.yml`
  pushes `ghcr.io/univers42/grobase-<svc>:latest` and `:sha-<commit>` on pushes
  to `main` (the pull-fallback the compose files reference).
- **SDK** (`@grobase/js`) ships IN-REPO (`sdks/js`) — consumed as a
  file dependency; **not published to npm** (the publish is a held human step,
  `HUMAN-ATOMS.md` §1).
- **realtime-agnostic** is vendored in-repo as plain tracked files
  (`infra/docker/services/realtime/realtime-agnostic/`), not an upstream image
  pin any more. Update procedure below.
- **Tag namespace** (monorepo history): `baas-vX.Y.Z` (bare `v*` belonged to
  other products), pre-releases `baas-vX.Y.Z-rc.N`. **This repo has no `baas-v*`
  tag** — `git tag` shows only `v0.0.1` and `backup/develop-2026-09-23`.
- **Scope (v1.0)**: images and binaries are **linux/amd64** only (the binocle
  Dockerfiles target x86_64-musl). arm64 is a v1.1 item.

## Pre-tag checklist (local, Docker-first)

```sh
make release-check            # automated part of this list
make verify-all               # all milestone gates — hard floor:
                              #   m21 (helm parity) · m28 (packages parity)
                              #   m32 (footprint budgets) · m37 (nano)
                              #   m40–m45 (one) · m46 (share-pools isolation)
make check-secrets            # no hardcoded secrets
# CI green on the release commit · SDK: npm run build && npm test (sdks/js)
# git status clean · .env untracked
```

Gate context notes (learned 2026-06-13):
- **m32/m33 measure LIVE RSS** — run them on a fresh tier-shaped stack
  (`make up PACKAGE=<tier>` after a `down`), not on a long-running box that
  load tests have inflated (one untrimmed Debezium CDC stream
  `mini_baas.public.outbox_events` alone held 250 MB of redis after a bench
  storm — its trim policy is a v1.1 item).
- **m46** needs `SHARE_POOLS_PROBE=1 SHARE_POOLS_EXPECT=0|1` (live probe).
- **m39** runs on the scale shape only (`DATA_PLANE_SHARE_POOLS=1`); on the
  base per-tenant-pool shape it SKIPs by design.

## Cut the release (monorepo pipeline — not wired in this repo)

Pushing these tags fires nothing here until a `baas-release.yml` equivalent is
re-added (see the standalone-repo note below). In the monorepo:

```sh
# 1. rc first — proves the whole pipeline end-to-end
git tag -a baas-v1.0.0-rc.1 -m "Grobase BaaS v1.0.0-rc.1" && git push origin baas-v1.0.0-rc.1
#    → watch the run: gates → bake-publish → binocle → github-release → monitor

# 2. the real thing
git tag -a baas-v1.0.0 -m "Grobase BaaS v1.0.0" && git push origin baas-v1.0.0
```

The manual pieces that do exist here (a push is irreversible — human trigger):
`make release-binaries` (binocle binaries + sha256 → `artifacts/release/`) and
`make release-images VERSION=X.Y.Z` (bake + push every suite image).

## Post-publish checklist

- [ ] `monitor` job green (monorepo pipeline) — it pulls the published binocle-one
      **anonymously** from Docker Hub (public by default on push; the probe IS the
      visibility check) and waits for the container healthcheck.
- [ ] **Clean-VM smoke** (~20 min, fresh Ubuntu with only git/curl/make/docker):
      Path A `docker run -d -p 8090:8090 dlesieur/binocle-one:X.Y.Z` → CRUD via curl
      (the `install.sh` tarball path needs GitHub Release assets, which this repo
      does not publish);
      Path B clone → `make quickstart` → `make health` green →
      `bash scripts/test/phase/phase1-smoke-test.sh`. Save the transcript to `artifacts/`.
- [ ] Release notes: lead with the SKU table below; numbers cite their artifact.

## SKU lineup (release-notes template)

| SKU | One line | Measured |
|---|---|---|
| **binocle-one** | Your PocketBase, smaller — accounts/OAuth2-PKCE/TOTP MFA/files/SSE/admin `/_/` in one static binary | 6.41 MB · ~2.2 MiB RSS · gates m40–m45 |
| **binocle-nano** | Headless embedded data plane (SQLite, CRUD+graph+keys+SSE) | 5.1 MB · 2.0 MiB RSS vs PocketBase 30.1 MB · 13.1 MiB (`artifacts/nano-vs-pocketbase.json`, written by `scripts/bench/nano-vs-pocketbase.sh`; `artifacts/` is gitignored) |
| **self-host basic** | Node-free Pi-class CRUD (Rust `/data/v1`) | ~460 MiB · 11 svc |
| **self-host essential** | The default: full product, aggregates | ~660 MiB · 13 svc |
| **self-host pro** | Multi-engine + realtime + storage + txns | ~1.4 GiB · 28 svc |
| **self-host max** | Everything incl. DDL + analytics | ~3.5 GiB · 41 svc |

## Updating the realtime service

The `realtime` service in `orchestrators/compose/base/data-plane.yml` builds from
the vendored `infra/docker/services/realtime/realtime-agnostic/` and falls back
to `ghcr.io/univers42/grobase-realtime:latest`, which `ci.yml` publishes from
`main`. There is no upstream image pin to bump.

1. Change the vendored source (or re-vendor a newer upstream release over it).
2. `docker compose build realtime` — local stacks build from source; pull-only
   deployments get the new image once CI has published it from `main`.
3. Re-verify: `make verify-m44` (SSE) + `bash scripts/test/phase/phase11-realtime-websocket-test.sh`.

Monorepo history: the pin was `dlesieur/realtime-agnostic:X.Y.Z`, published by
tagging `vX.Y.Z` in `Univers42/realtime-agnostic`. **Gotcha (bit v0.2.0 and
v0.2.1):** that publish job needs repo secrets `DOCKER_HUB_USERNAME` /
`DOCKER_HUB_TOKEN` — without them the binary/Release jobs go green but the
image job fails at login.

## Standalone-repo note

This repo (`Univers42/grobase`) is the standalone product repo, extracted from
the Track-Binocle monorepo; the older standalone sync target (history:
`Univers42/mini-baas-infra`) is superseded. v1.0 shipped from the monorepo
(`baas-v*` tags). Moving the release home here (a `baas-release.yml`
equivalent, `baas-v*` tags, GitHub Release assets) is still open — see
`HUMAN-ATOMS.md` §2.
