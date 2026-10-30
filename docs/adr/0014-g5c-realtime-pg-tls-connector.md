# 0014 — Realtime's Postgres producer can dial TLS (opt-in by DSN)

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, R-TLS1–R-TLS12). Opt-in by DSN; no deploy.

## Problem

`crates/realtime-db-postgres/src/producer/lifecycle.rs` `connect_pg` dialled every DSN with
`NoTls`, and both `attach()` and `health_check()` go through it. Realtime was the one Postgres
client that could not negotiate TLS, so a later "Postgres refuses plaintext" step would cut its
LISTEN off.

## Decision

- **Copied, not shared.** `src/producer/tls.rs` copies the behaviour of
  `src/data-plane-router/crates/data-plane-pool/src/postgres/conn.rs`. The realtime workspace is
  its own Cargo workspace with its own Docker build context (`ci.yml` infra-build realtime leg),
  so depending on the pool crate would pull the router tree into that context.
- **Parsed, not matched.** `sslmode` is read with tokio-postgres 0.7.18's own grammar. In URL
  form the credentials end at the first `@`, the query starts at the next `?`, and pairs split
  on `&` and the first `=`, percent-decoded, with the last one winning. In key=value form, quoted
  values and backslash escapes are honoured. A password holding `sslmode=verify-full` is never
  read as the mode. The pool's copy still uses a substring match; that latent bug is out of
  scope here.
- **`prefer` stays `NoTls`.** `verify-full`/`verify-ca` give `Verify`, and `require` gives
  `Require`. Anything else (`disable`, `allow`, `prefer`, absent or unknown) keeps today's exact
  `NoTls` call and DSN. Handing a connector to `prefer` would silently upgrade it to unverified
  TLS.
- **`SECURITY_MODE=max` upgrades `require` to `Verify`**, as the data plane does. It already
  reaches realtime through compose.
- **Wire rewrite.** tokio-postgres refuses `sslmode=verify-*`, so `wire_dsn` rewrites only that
  value to `require` and leaves every other byte unchanged. Verification happens in the rustls
  connector, chosen from the original DSN.
- **Connector.** It uses ring.
  - `Verify` trusts the webpki roots plus the PEMs in `REALTIME_PG_TLS_CA_FILE`, and checks the
    host name. A CA file that is set but unreadable, unparseable or empty is an error naming the
    path. It never falls back to roots-only or to plaintext.
  - `Require` accepts any certificate (libpq semantics: encryption without authentication),
    marked with a `Caveat:` comment.
- **One choice point.** `connect_pg` returns `(Client, PgStream)` from both branches, so `attach`
  and `health_check` dial the same way.
- **Deps.** The data plane's exact versions: `tokio-postgres-rustls` 0.13, `rustls` 0.23
  (ring, logging, std, tls12), `webpki-roots` 1 and `rustls-pemfile` 2. No `aws-lc-rs`.

## What it does not do

- **It changes no compose, env, helm or VM file (R-TLS11).** No live DSN carries `sslmode` until
  someone sets it.
- **There is no CA mount yet.** Realtime has none today, so a `SECURITY_MODE=max` stack with a
  `require` DSN fails closed until `REALTIME_PG_TLS_CA_FILE` is mounted.
- **Enabling it on the VM needs:**
  - a fresh go;
  - the realtime R1 F1–F3 and F1-verdict B0–B7 traps;
  - first, a count (never a print) of whether the live DSN carries `sslmode`.
- **No TLS client certificates.** The producer does not present one.

## Evidence

`scripts/verify/m258-realtime-pg-tls.sh` mints a throwaway CA and engine cert, then starts
postgres:16-alpine behind the G5a `engine-tls-entrypoint.sh`. It then runs
`cargo test -p realtime-db-postgres --test tls -- --ignored`, then fmt `--check`, clippy
`-D warnings` and the lib tests. Measured on 2026-10-30:

```
require: backend ssl=true version=Some("TLSv1.3")
refused as expected: Internal error: PostgreSQL connect failed: error performing TLS handshake
verify-full: backend ssl=true version=Some("TLSv1.3")
✓ fmt clean, clippy clean, 11 passed unit tests
[M258] ALL GATES GREEN
```

The refused case dials the same server under a network alias outside the certificate's SANs. No
backend carrying its `application_name` appears in `pg_stat_activity`, so nothing fell back to
plaintext. `scripts/verify/m184-realtime-listen-reconnect.sh` (plaintext, `tests/reconnect.rs`
unchanged) stays green, which shows the `NoTls` path is untouched (R-TLS1).
