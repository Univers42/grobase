# 0024 — The Rust redis clients dial `rediss://` verified (opt-in by DSN)

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, D3 R1–R13). Opt-in by DSN; no deploy.

## Problem

G5b (ADR 0012) made redis serve TLS on 6380, but no client could use it. Workspace redis
0.27.6 was built without a TLS feature (G5b-C9), so the pool's redis engine and the server's
limiter / quota / metering link (`data-plane-server/src/redis_link.rs`) could only dial
plaintext `redis://…:6379`.

## Decision

- **rustls, one crate.** Workspace redis gains `tokio-rustls-comp` (R1). The lockfile adds
  exactly one package, `rustls-native-certs` 0.7.3. rustls, tokio-rustls, rustls-pemfile and ring
  were already locked. `native-tls` was rejected because it needs openssl, and the scratch
  images (`Dockerfile.nano` / `.one`, musl) ship none. `tls-rustls-insecure` is NOT enabled.
- **One constructor.** `data_plane_pool::redis_client` (`src/redis_tls.rs`) builds every Rust
  redis client: the pool dial (`redis/dial.rs connect_dsn`) and `redis_link::connect`. The server
  reaches it through the pool's `redis-tls` feature, which `ratelimit-redis` enables. A
  `redis://` URL is built exactly as before and reads no TLS setting.
- **The CA is added, not substituted (R3).** redis replaces its whole root store with any
  `root_cert` it is given (`create_rustls_config`). `tls::root_bundle` therefore hands it the
  system store plus the PEMs in `DATA_PLANE_TLS_CA_FILE`, using the same `tls_ca_pem` reader as
  the mysql adapter (lifted into `tls.rs` in its own commit). With no CA file the crate's own
  native-root path runs unchanged. A CA file that is not PEM, holds no certificate, or holds a
  certificate that is not a trust anchor is an error at client build. It never falls back to
  the system store alone.
- **The crypto provider is installed at startup (R5).** `rustls::ClientConfig::builder()` panics
  when ring and aws-lc-rs are both linked (`--features dynamodb`). The server calls
  `ensure_crypto_provider()` once after tracing init, and `redis_client` calls it again
  (idempotent) for the pool-only callers.
- **The dial guard still refuses TLS under scope (R4).** TcpTls dials by host name and uses it as
  SNI, and redis has no hook to pin an IP while verifying a name. Under a dial-guard scope
  `rediss://` is refused as `DenyClass::Tls`, and `pinned_info` now errors for anything but
  plain TCP. It used to rewrite TcpTls to plaintext `Tcp(ip)`, a silent downgrade.
- **`#insecure` is refused (R6).** It is refused unless `DATA_PLANE_TLS_INSECURE=1`, and always
  under `SECURITY_MODE=max`. Even with the opt-in, the crate refuses at connect because
  `tls-rustls-insecure` is not compiled in. An unverified session cannot be produced.
- **Posture from the parsed address.** The probe reports `Verified` for TcpTls and `Plaintext`
  otherwise. It reads `ConnectionAddr`, not the URL string.
- **Consumers keep their bound and failure mode (R8).** The link connect keeps a 1 s timeout and
  0 retries. A TLS failure is a connect `Err`, so each consumer degrades exactly as on a refused
  dial:
  - the limiter admits (`ratelimit.rs:229-233`);
  - quota keeps its prior snapshot (`quota.rs:166-174`);
  - usage drops the window (`usage.rs:388-397`).

## Caveats

- Caveat: in an image with no system store (`FROM scratch`), `rustls-native-certs` finds nothing.
  Only `DATA_PLANE_TLS_CA_FILE` is then trusted, and without it every `rediss://` dial is refused
  (fail closed, R9). An unreadable store is logged and treated as empty. `SSL_CERT_FILE` /
  `SSL_CERT_DIR` override the store.
- The system store is re-read on every connect. redis 0.27.6 does this itself
  (`create_rustls_config`) whether or not a CA is set, so caching it in `root_bundle` would save
  nothing.

## Not done

- Compose defaults stay `redis://…:6379` (R2). Nothing switches until a DSN says `rediss://`.
- The realtime-gateway's shared presence (`presence_shared.rs`) has its own workspace, lockfile
  and VM-live image, so it stays plaintext. Its swap needs its own window (R12).
- There is no "query-router cache" client (R13).

## Evidence

- `scripts/verify/m260-redis-client-tls.sh` (CI job `redis-client-tls`) boots redis behind the
  G5b overlay under its own compose project and runs the real clients in a `--features
  dynamodb` build. It checks that:
  - the CA verifies;
  - a wrong CA and a name outside the SANs are refused;
  - an empty store fails closed;
  - plaintext 6379 is unchanged;
  - the server's honor-set refresh works over rediss.
- `m230` gains a canary anchor: a refused `rediss://` dial never repeats the password.
