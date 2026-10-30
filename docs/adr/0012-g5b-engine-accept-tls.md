# 0012 — Mongo, Redis and MySQL/MariaDB accept TLS, each behind its own opt-in

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, C1–C15). Code: mongo. Redis and
MySQL/MariaDB follow, one engine per commit (C12). Not on the VM: C13.

## Problem

G5a (ADR 0011) gave the central Postgres accept-mode TLS behind `ENGINE_TLS=1`. Doing the same for
the other engines broke four of G5a's premises, all measured on 2026-10-30 against the ghcr
`grobase-*:latest` images:

- **No image runs as root.** Redis and MariaDB run as 100:101, mongo as 999:999. They refuse a
  0600 key owned by the host uid ("Permission denied", "Unable to get private key"). G5a's
  `install -o postgres` worked only because the Postgres entrypoint starts as root.
- **A shared knob takes down every G5a host.** If `ENGINE_TLS=1` also meant mongo, Redis and
  MariaDB, every host already on it would recreate them on the next `make up`, and they would
  fail closed with no cert. Redis has about 20 consumers.
- **A nested cert directory leaks keys.** Postgres mounts `certs/engines`. A `certs/engines/mongo`
  directory would sit inside that mount and hand Postgres mongo's key.
- **An overlay `entrypoint` clears the image CMD.** The mysql and mariadb entrypoints dispatch on
  `$1`, and neither service has a compose `command`.

## Decision

- **One knob per engine (C1).** `ENGINE_TLS_ENGINES="mongo"` lists the engines, from the
  environment or from an `ENGINE_TLS_ENGINES=` line in `.env.local`. `00-config.mk` adds
  `docker-compose.engine-tls-<engine>.yml` for each name. `ENGINE_TLS=1` keeps meaning Postgres
  only.
- **The default is untouched (C2).** With the knob unset, no overlay is composed, so the resolved
  services are byte-identical. m247 static checks that no default service sets a TLS flag.
- **Root only long enough to hand the key over (C3).**
  1. The overlay runs the shared `infra/docker/services/engine-tls/drop-entrypoint.sh` as
     `user: "0"`.
  2. It copies the key into the tmpfs `/run/engine-tls` (0700) at 600, owned by the image's uid.
  3. It then runs `exec setpriv --reuid --regid --clear-groups` into the image's own entrypoint.
  - m247 live asserts that PID 1's `Uid` is the image uid, and checks the copy's mode and owner.
- **Flags are appended, never restated (C4).** Mongo and Redis add their flags to `"$@"`, the
  compose `command`. MySQL/MariaDB will restate `command: ["mysqld"]` / `["mariadbd"]` because
  they have none.
- **Sibling cert directories (C5).**
  - `generate-engine-cert.sh <engine>` writes to `certs/engine-tls/<engine>/`, with that
    engine's own SANs. mongo's are `mongo`, `mini-baas-mongo`, `localhost` and `127.0.0.1`.
  - The reuse check matches that whole SAN line.
  - Postgres stays at `certs/engines`, so no host on G5a has to move its cert.
- **The measured flag sets (C6).** Mongo:
  - `--tlsMode allowTLS`
  - `--tlsCertificateKeyFile` (key and cert combined on the tmpfs)
  - `--tlsCAFile`
  - `--tlsAllowConnectionsWithoutCertificates`
  The initdb `mongod` the entrypoint starts on a fresh volume binds 127.0.0.1 without TLS, as
  before.
- **Fail closed (C8).** An engine selected without a cert exits, and the message names
  `generate-engine-cert.sh <engine>`.

## Consequences

- **m247.** `M247_LIVE=1 M247_ENGINE=mongo` boots the real service three times under the throwaway
  project m247:
  - **A:** no overlay. `getCmdLineOpts` shows no `net.tls`.
  - **C:** overlay with no cert. The container refuses to start.
  - **B:** overlay with a cert:
    - a verified `--tls` session works, with `net.tls.mode` allowTLS;
    - a name outside the SANs is refused;
    - a default plaintext mongosh still connects (C7);
    - PID 1 is uid 999;
    - nothing lands in `/data/db`.
  Measured locally on 2026-10-30: all green. The Postgres legs are re-run unchanged.
- **CI (C11).** The `mongodb` engine-conformance leg runs twice: as before, and with `tls: mongo`.
  The `tls: mongo` run initiates the replica set under the overlay, runs m27 and then runs m247
  live.
- **Renewal.** Re-run `generate-engine-cert.sh <engine>`, then recreate that engine. The script
  says when it issued a new cert.
- **The VM (C13).** No pin or rollout outside a confirmed G5 window, one engine per window. A
  Redis recreate is announced as touching every consumer, and every network path is probed
  after it.

## Not done here

- **No client verifies mongo's cert yet.** mongosh, mongo-init, mongo-api and the pool still dial
  plaintext, which accept mode allows. Moving them is the next G5 step.
- **Pool Redis TLS is out of scope (C9).** redis 0.27.6 is built without a TLS feature. It needs
  its own ruling.
- **Oracle mysql8 TLS needs its own ruling (C14).** `auto_generate_certs` writes keys into the
  datadir.
