# 0029 — CockroachDB runs in secure mode with the CA-signed engine cert, plaintext still accepted, behind its own opt-in

- Status: accepted. devil ruled PROCEED-WITH-CONDITIONS on 2026-10-30, conditions CR1–CR12. On develop (4d83e748). CR8 met: the `cockroachdb over TLS` CI leg is green on develop runs 41080324791, 41086854436 and 41089119419.
- Date: 2026-10-30
- Deciders: devil (ruling). Whoever composes `ENGINE_TLS_ENGINES=cockroach` lives with the outcome.

## Context

- `cockroach` (`orchestrators/compose/base/engines-extra.yml`, profile `engines-extra`) runs `start-single-node --insecure`. Its healthcheck and five host clients dial `cockroach sql --insecure`. Every in-repo DSN logs in as passwordless root.
- CockroachDB has no TLS accept mode in insecure mode. The devil measured the following on v24.3.5 (probe `g5r/crdb.sh`):
  - Secure mode alone refuses every `sslmode=disable` client (08P01).
  - With `--accept-sql-without-tls`, a password user connects in plaintext, and passwordless root is refused (28P01).
  - An insecure node ignores a password in the DSN.
  - `ALTER USER ... PASSWORD` is refused on an insecure node. So the first password needs the root client cert (CN=root, clientAuth).

## Decision

- **Opt-in (CR1).** `orchestrators/compose/docker-compose.engine-tls-cockroach.yml` is composed only when `ENGINE_TLS_ENGINES` lists `cockroach`. The overlay passes `--certs-dir` and `--accept-sql-without-tls` (CR2), and nothing else changes.
- **Root's password (CR3).** `COCKROACH_PASSWORD` is 24 random bytes, hex, in `GENERATED_KEYS` (`scripts/env/generate-env.sh`).
  - It reaches the node as a compose secret (`environment:` source, mode 0400). It never appears in the container env, in argv, or in `docker inspect`.
  - The overlay's healthcheck, `infra/docker/services/engine-tls/cockroach-health.sh`, logs in with the root client cert. On the first run of each boot it pipes `ALTER USER root WITH PASSWORD` on stdin. The value is spliced in only after it passes a hex check.
  - Re-running it after a restart is a no-op.
  - Compose refuses to start the overlay when the variable is unset: `environment variable "COCKROACH_PASSWORD" required by secret`.
- **Certs (CR4).** `scripts/certs/generate-engine-cert.sh cockroach` issues the node cert, with SANs `cockroach, mini-baas-cockroach, localhost, 127.0.0.1`, into `certs/engine-tls/cockroach`.
  - It also issues a `client.root` cert (CN=root, clientAuth) into the sibling `certs/engine-tls/cockroach-client`. Only the cockroach overlay mounts that directory, and m247 checks this.
  - The new `issue_leaf` helper mints both certs.
- **Wrapper (CR5).** The `cockroach)` case of `drop-entrypoint.sh` copies the files into `/run/engine-tls/certs`, which is tmpfs, 0700, owned by uid 1001. It uses the layout cockroach expects: `ca.crt`, `node.crt/key`, `client.root.crt/key`, keys 600.
  - It refuses to start without the client cert or with a non-hex password.
  - `setpriv` drops to uid 1001.
- **Clients (CR6).** `scripts/lib/lib-crdb-client.sh` provides two helpers:
  - `crdb_auth` returns `--certs-dir` when the root client cert is on the tmpfs, and `--insecure` otherwise. engine-backup, stack-health-requests, multidb-workspace and m188 use it.
  - `crdb_dsn` builds `root:<password>@` whenever a password exists. The seed registration and m27 use it, so one DSN serves both modes.
- **Healthcheck (CR7).** The overlay restates the healthcheck.
- **CI (CR8).** The `engine-conformance` matrix gains the leg `{ engine: cockroachdb, tls: cockroach }`, and `M27_PG_TLS_CA` now covers cockroachdb.

## Evidence (scripts/verify/m247-engine-tls.sh, legs in scripts/lib/lib-m247-cockroach.sh)

- **Static.**
  - The default is still `--insecure`, and the overlay is secure with `--accept-sql-without-tls`.
  - The healthcheck is restated and the secret is 0400.
  - `COCKROACH_PASSWORD` appears outside the secret in no non-comment line.
  - The client dir is mounted by this overlay only.
  - No `cockroach sql --insecure` is left in `scripts/`.
  - Mutants that each removed one of the flag, the 0400 mode, the 8080 Caveat or the env-only rule all turned the gate red.
- **Default render.** `docker compose --profile engines-extra config | sha256sum` is `3d662665…` both before and after, on the same `.env`.
  - An `.env` regenerated with the new key differs only by `COCKROACH_PASSWORD`, as with any `GENERATED_KEYS` addition.
- **Live run** (`M247_LIVE=1 M247_ENGINE=cockroach M247_PROJECT=m247-crdb`, green 2026-10-30):
  - **Leg A:** the default node is plaintext-only and takes the password DSN.
  - **Leg C:** with no cert, the node refuses to start and names the cert script.
  - **Leg B (CR9):**
    - verify-full works as root:<password>, and plaintext with the password still connects.
    - Passwordless root is refused with 28P01.
    - `openssl s_client -starttls postgres -verify_hostname cockroach` returns 0 (ok), and the container name gets `hostname mismatch`.
    - PID 1 is uid 1001, the keys are 600 uid 1001, and the secret is 0400.
    - No key or cert is in the store, and the password does not appear in `docker inspect`.
    - The password survives a restart.
    - 8080 answers plain HTTP.
  - **Leg D (CR12):** the overlay is dropped and the same store boots `--insecure`. The database created under the overlay and the password DSN both survive.
- **m27, run locally** under the overlay with an isolated project:
  - cockroachdb is green over verify-full.
  - A CA that signed nothing fails at the TLS handshake (exit 101).
  - Without the overlay, the password DSN is green on the default node.

## Consequences

- Turning the overlay on means every client must use the password. A passwordless root DSN outside this repo gets 28P01 under the overlay.
- 8080 (admin UI, `/health`) still serves plain HTTP. In the live run `/health` returned 503, not the 200 the devil saw. The overlay's Caveat records this (CR11).
- This proves cockroach CAN serve a verifiable cert, not that every client checks it. `--accept-sql-without-tls` keeps `sslmode=disable` working.
- **Deviation from CR4's wording.** The host directory keeps the shared `engine.pem/engine-key.pem/ca.pem` contract, and the wrapper builds cockroach's `ca.crt/node.*/client.root.*` layout on the tmpfs. So the per-overlay static loop and `refuses_without_cert` apply unchanged.
- **No VM change (CR10).** The VM still runs `--insecure`. Its cockroachdb mount DSN (ADR 0017) is passwordless root and needs a PATCH (ADR 0010) to root:<password> before any secure window.

## Not done here

- Not verified: whether a libpq `prefer` client actually negotiates TLS, because cockroach has no `pg_stat_ssl`. Multi-node clientAuth is also not verified.
- Requiring TLS, which would mean dropping `--accept-sql-without-tls`, and moving any consumer DSN to verify-full.
- Securing the HTTP port.
