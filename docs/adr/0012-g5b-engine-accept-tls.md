# 0012 — Mongo, Redis and MySQL/MariaDB accept TLS, each behind its own opt-in

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, C1–C15). Code: mongo, redis, mariadb.
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
  - The self-built Alpine redis image only had BusyBox's `setpriv`, which has no `--reuid`,
    `--regid` or `--clear-groups`. Its Dockerfile adds Alpine's `setpriv` package (33 KiB).
    An image without it fails closed: the wrapper checks for `--reuid` before it copies a key.
- **Flags are appended, never restated (C4).** Mongo and Redis add their flags to `"$@"`, the
  compose `command`. MariaDB has none, so its overlay restates `command: ["mariadbd"]`; the
  `mysql` service will restate `["mysqld"]`.
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
  before. Redis:
  - `--tls-port 6380` with the cert, key and CA files, and `--tls-auth-clients no`
  - 6379 stays plaintext. 6380 is never published: the overlay has no `ports`, and m247
    static checks that.
  MariaDB:
  - `--ssl-cert`, `--ssl-key` and `--ssl-ca` on the tmpfs copies.
  - 11.4 already serves TLS with a self-signed cert that no client can verify against the local
    CA; the flags replace that cert. `require_secure_transport` stays off, so `--skip-ssl`
    still connects.
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
  `M247_ENGINE=redis` runs the same three legs:
  - **A:** `tls-port` is 0.
  - **C:** the container refuses to start without a cert.
  - **B:** a verified `redis-cli --tls` PING on 6380 works; 6379 still answers plaintext;
    plaintext on 6380 is refused; PID 1 is uid 100; nothing lands in `/data`.
  - `redis-cli` verifies the chain but never the host name, so the SAN legs run
    `openssl s_client -verify_hostname` from the host: `redis` verifies and `m247-redis` is
    refused with "hostname mismatch".
  - `M247_IMAGE` points the boots at a local build, so a test never retags the image a
    running stack uses. Measured locally on 2026-10-30: all green.
  `M247_ENGINE=mariadb` runs the same three legs:
  - **A:** `--skip-ssl` gets a plaintext session, and the default cert does not verify
    against the local CA.
  - **C:** the container refuses to start without a cert.
  - **B:** a `--ssl-ca --ssl-verify-server-cert` session gets TLSv1.2 or 1.3;
    `openssl s_client -starttls mysql -verify_hostname` verifies `mariadb` and refuses
    `m247-mariadb` with "hostname mismatch"; `--skip-ssl` still connects; PID 1 is uid 100; the key copy is
    600 uid 100; nothing lands in `/var/lib/mysql`.
  - The legs found `mariadb-install-db`'s passwordless `root@<hostname>`, `@127.0.0.1` and
    `@::1`; the mysql and mariadb entrypoints now drop them on first boot. Measured locally
    on 2026-10-30: all green, and m27 mariadb under the overlay 12 passed / 0 failed.
- **CI (C11).** The `mongodb` engine-conformance leg runs twice: as before, and with `tls: mongo`.
  The `tls: mongo` run initiates the replica set under the overlay, runs m27 and then runs m247
  live. The `mariadb` leg runs twice the same way, with `tls: mariadb`; it builds the image from
  the commit first, since the published one has no util-linux `setpriv`. Redis has no
  conformance leg. A CI step builds its image from the commit and runs the
  m247 redis legs.
- **Renewal.** Re-run `generate-engine-cert.sh <engine>`, then recreate that engine. The script
  says when it issued a new cert.
- **The VM (C13).** No pin or rollout outside a confirmed G5 window, one engine per window. A
  Redis recreate is announced as touching every consumer, and every network path is probed
  after it.

## Not done here

- **No client verifies mongo's, redis's or mariadb's cert yet.** mongosh, mongo-init, mongo-api,
  the pool and every redis consumer still dial plaintext, which accept mode allows. Pool mysql
  mounts can trust the CA (`DATA_PLANE_TLS_CA_FILE`, C10), but no mount asks for TLS yet. Moving them is the next G5
  step.
- **The published redis and mariadb images lack `setpriv` until a main push republishes them.**
  Until then, `ENGINE_TLS_ENGINES=redis` (or `mariadb`) on a host that pulls `:latest` fails closed with the wrapper's
  message; `make build` fixes it.
- **The `mysql` service (MariaDB 11.4, `data-plane` profile) has no overlay yet.** It is its own
  commit (C12) and restates `command: ["mysqld"]`.
- **Pool Redis TLS is out of scope (C9).** redis 0.27.6 is built without a TLS feature. It needs
  its own ruling.
- **Oracle mysql8 TLS needs its own ruling (C14).** `auto_generate_certs` writes keys into the
  datadir.
