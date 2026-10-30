# 0027 — Under the mssql engine-TLS overlay, the data plane verifies the bundled mssql (DATA_PLANE_TLS_INSECURE=0, engine CA pinned); the compose default stays 1

- Status: accepted. devil 2026-10-30: flipping the compose default to `:-0` is BLOCKED (5a). Scoping the flip to the mssql overlay is PROCEED-WITH-CONDITIONS, D1–D9 (5b). Code on branch `feat/g5-mysql8-mssql-verify`; CI is unconfirmed until push.
- Date: 2026-10-30
- Deciders: devil (ruling). Operators who compose `ENGINE_TLS_ENGINES=mssql` live with the outcome.

## Context

- `DATA_PLANE_TLS_INSECURE` is read in one place, `data-plane-pool/src/mssql/adapter.rs:146-147`, and `SECURITY_MODE=max` already ignores it. Its compose defaults are `${DATA_PLANE_TLS_INSECURE:-1}` at `orchestrators/compose/base/data-plane.yml:99` and `orchestrators/compose/docker-compose.monolith.yml:1105`.
- The VM was read over read-only ssh on 2026-10-30 (`/opt/grobase`, main a855f86b):
  - The data plane runs with `INSECURE=1`, `SECURITY_MODE=baseline` and an empty `CA_FILE`.
  - No env or config file sets `DATA_PLANE_TLS_INSECURE`, so the 1 comes from the compose default alone.
  - The VM has `certs/track-binocle-local-ca.pem`. It has no `certs/engine-tls`.
  - So a flipped default, or a flip keyed on the local CA, would flip the VM at its next data-plane recreate.
- The data plane mounted only `sqlite-data:/tmp` (`data-plane.yml:131-132`).
- tiberius 0.12.3 `trust_cert_ca` builds `RootCertStore::empty()` plus exactly one cert, and accepts only `.pem/.crt/.der` (`rustls_tls_stream.rs:80-105`). It **replaces** the native roots.
- Other adapters **add** the CA instead: Postgres (`postgres/conn.rs:194-208`) and MySQL (`mysql/tls.rs:32-37`).
- m27 hard-coded `DATA_PLANE_TLS_INSECURE=1`, so the CI mssql TLS leg never exercised a verified pool.

## Decision

- The compose defaults stay 1 (D1).
- `orchestrators/compose/docker-compose.engine-tls-mssql.yml`, and only that file, does two things for `data-plane-router-rust` (D2, D3):
  - It sets `DATA_PLANE_TLS_INSECURE: "0"` and `DATA_PLANE_TLS_CA_FILE: /etc/engine-tls-ca/mssql-ca.pem`.
  - It bind-mounts `${ENGINE_TLS_MSSQL_CERT_DIR:-./certs/engine-tls/mssql}/ca.pem` there: one file, `read_only`, `create_host_path: false`. It never mounts the local CA or its directory.
- Max mode is unchanged (D6): it already ignored the escape.

## Evidence

- `scripts/verify/m247-engine-tls.sh`, with its legs in `scripts/lib/lib-m247-mssql-plane.sh`:
  - Static: both defaults are `:-1` (D1). The overlay's data-plane block is asserted (D2, D3). `git grep` finds no committed env, config, compose or JSON file outside the overlay that sets `DATA_PLANE_TLS_INSECURE` to 0 (D8).
  - Live (`M247_ENGINE=mssql`): the rendered data plane is `INSECURE=1` with no CA without the overlay, and `INSECURE=0` with the engine CA mounted with it. Dropping the file is the rollback (D9).
- `scripts/verify/m27-conformance.sh` (D5):
  - `M27_MSSQL_TLS_CA` runs the battery with `INSECURE=0` and that CA pinned. The CI TLS leg is verified, 10 passed, against the overlay's cert.
  - `M27_MSSQL_EXPECT=refused` first runs the unchanged escape leg on the same server, which must be green. Then the pinned run must fail at its first checkout. CI runs this on the plain mssql leg, whose server keeps its default self-signed cert.
  - The existing leg (no CA, `INSECURE=1`) is unchanged.

## Consequences

- Caveat: while the overlay is on, the data plane trusts the mssql engine CA **instead of** the native roots for every mssql mount. A remote mssql behind a public CA then fails its handshake. An operator's own `DATA_PLANE_TLS_CA_FILE` is overridden too. Postgres and MySQL mounts add the CA and are unaffected.
- Caveat: bb8 reports every dial error as `Timed out in bb8`, so the refusal leg cannot name the certificate. It attributes the failure by control: same server, same DSN, only the trust changed. A server that dies between the two runs would read as a refusal.
- Composing the overlay recreates the data plane. With no `ca.pem`, the bind fails and the data plane does not start, so it fails closed.
- No VM change (D7): the VM has no `certs/engine-tls` and does not compose the overlay.

## Not done here

- Changing the default to 0 (BLOCKED, 5a).
- Per-mount CA pinning, which would let a public-CA remote mssql and the bundled one coexist.
- An error sink on the mssql pool that would surface the rustls reason.
