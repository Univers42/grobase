# 0026 — Oracle MySQL 8.4 (mysql8) accepts TLS with the CA-signed engine cert, behind its own opt-in

- Status: accepted. devil ruled PROCEED-WITH-CONDITIONS on 2026-10-30, conditions M1–M7 (answers G5b-C14). On develop (f9605fb5). M5 met: the `mysql8 over TLS` CI leg is green on develop runs 41080324791, 41086854436 and 41089119419.
- Date: 2026-10-30
- Deciders: devil (ruling). Whoever composes `ENGINE_TLS_ENGINES=mysql8` lives with the outcome.

## Context

- The `mysql` service is MariaDB 11.4. `mysql8` is the real Oracle server, `ghcr.io/univers42/grobase-mysql8:latest` (MySQL 8.4.9), defined in `orchestrators/compose/base/engines-extra.yml:49-86`, profile `mysql8`. It has no compose `command`, and the image CMD is `["mysqld"]`.
- The following was measured 2026-10-30 on throwaway containers (devil probe `g5r/mysql8.sh`):
  - The image runs as uid/gid 999 (`id mysql` gives `uid=999 gid=999`). Its `setpriv` is util-linux and has `--reuid`, so no image rebuild is needed.
  - A default boot already serves TLS (`auto_generate_certs=1`; a default client session is TLSv1.3). The cert is `MySQL_Server_8.4.9_Auto_Generated`, which does not verify for host `mysql8`.
  - The datadir holds `ca-key.pem` (600), `ca.pem`, `client-cert/key`, `private_key.pem` (600), `public_key.pem` and `server-cert/key`. They are there on the default boot and also on a fresh volume first booted under the overlay. The cause is the entrypoint's `mysqld --initialize-insecure`, which runs without the ssl flags. G5b-C14's worry is therefore pre-existing, not caused by the overlay.
  - With `--ssl-cert/--ssl-key/--ssl-ca` on the tmpfs, `ssl_cert` is `/run/engine-tls/server.crt`, and `VERIFY_IDENTITY` negotiates TLSv1.3. `--ssl-mode=DISABLED` still connects in plaintext.

## Decision

- `scripts/certs/generate-engine-cert.sh mysql8` issues the cert. Its SANs are `mysql8, mini-baas-mysql8, localhost, 127.0.0.1`, and it goes into `certs/engine-tls/mysql8`, a sibling directory (M1).
- `orchestrators/compose/docker-compose.engine-tls-mysql8.yml` is composed only when `ENGINE_TLS_ENGINES` lists `mysql8` (M2):
  - It restates `command: ["mysqld"]`.
  - It sets `ENGINE_TLS_UID/GID` to 999, not MariaDB's 100/101.
  - It reuses the `mariadb | mysql` flag set in `infra/docker/services/engine-tls/drop-entrypoint.sh`.
- Accept mode only: `require_secure_transport` stays off.
- The auto-generated datadir pems are left alone. They are never deleted or rotated, and nothing touches init. `private_key.pem` serves the caching_sha2 RSA exchange (M4).

## Evidence (scripts/verify/m247-engine-tls.sh, legs in scripts/lib/lib-m247-mysql8.sh)

- Static (M6): the per-overlay loop covers `docker-compose.engine-tls-mysql8.yml`, and `mysql8_static_checks` asserts the CMD, the uid/gid and the flag case. The default render is byte-identical with and without this change.
- Live, `M247_LIVE=1 M247_ENGINE=mysql8`:
  - Leg A: the default cert does not verify against the local CA, and `--ssl-mode=DISABLED` is plaintext.
  - Leg C: with no cert, the container refuses to start.
  - Leg B (M3): `VERIFY_IDENTITY` works. The served cert's SHA-256 fingerprint equals the overlay's `engine.pem`. A name outside the SANs is refused. `DISABLED` still connects. PID 1 is uid 999 and the key is 600 uid 999 on tmpfs. No file under `/var/lib/mysql` holds a line of the overlay key, with a positive control on `/run/engine-tls`.
- CI (M5): the `engine-conformance` matrix leg `{ engine: mysql8, tls: mysql8 }` has no `build`.

## Consequences

- "Nothing in the datadir" cannot be claimed for mysql8, unlike Postgres/MariaDB. The claim is narrower: the overlay key is not there.
  Caveat: the datadir check is a literal search for one base64 line of the PEM, so a re-encoded copy (DER, another wrapping) would go unnoticed.
- This proves mysql8 CAN serve a verifiable cert, not that any client checks it. The pool dials without `require_ssl` until a DSN asks for it.
- No VM change (M7): the VM does not compose this overlay.

## Not done here

- Removing `ca-key.pem` from the datadir. That would need a change to init, which M4 forbids.
- Requiring TLS (`require_secure_transport=ON`) or switching any consumer DSN to verified TLS.
