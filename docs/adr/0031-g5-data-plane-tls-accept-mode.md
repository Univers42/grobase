# 0031 — The data plane accepts TLS on :4012 beside plaintext :4011, through one opt-in overlay

- Status: proposed. devil ruled PROCEED-WITH-CONDITIONS on 2026-10-30 for the develop overlay (DT1–DT18). Nothing changes on the VM.
- Date: 2026-10-30
- Deciders: devil (ruling). Whoever composes `ENGINE_TLS_ENGINES=data-plane` lives with the outcome.

## Context

- data-plane-router-rust serves plain HTTP/1.1 on :4011 only. Its two signing callers, query-router (Node, axios on the global https agent) and tenant-control (Go, two `http.Client`s on `DefaultTransport`, `src/control-plane/internal/tenants/dataplane.go:47-55`), send the HMAC-signed body and the inline DSN in clear on that hop.
- Kong also proxies to :4011 and holds no CA for it. Its upstream TLS needs a `ca_certificates` entity plus `tls_verify: true` (ADR 0030, k1/k5), and that work is its own window.
- The image is distroless and runs as uid 65532 (`nonroot`), with no shell, so a root-owned 0600 key from `generate-engine-cert.sh` is unreadable inside it.
- The router stack has no TLS dependency yet. axum's `serve` cannot take a TLS stream, and the default `tokio-rustls` features pull in aws-lc-rs.
- tenant-control already trusts the cloud MinIO CA through `SSL_CERT_DIR` in `docker-compose.cloud-minio-tls.yml`. A second overlay that sets the same variable would replace that list.

## Decision

- Accept mode, as in G5a. The router keeps :4011 unchanged and adds a TLS listener with the same routes on the port `DATA_PLANE_ROUTER_TLS_PORT` names (default 4012). The listener starts only when both `DATA_PLANE_ROUTER_TLS_CERT_FILE` and `DATA_PLANE_ROUTER_TLS_KEY_FILE` are set (DT8, DT9). Code: `crates/data-plane-server/src/tls_listener.rs`, wired in `src/server.rs:28,50-62`.
- Boot refuses (DT7), naming the variable and never the key bytes, when:
  - only one of the two variables is set;
  - the cert or the key is unreadable;
  - the key does not fit the cert;
  - the TLS port equals the plaintext port;
  - the TLS bind fails.
- `tokio-rustls` uses ring only, with `default-features = false` and `ring`, `tls12`, `logging`. aws-lc-rs is absent from the default build, and `Cargo.lock` gains no package (DT2).
- HTTP/1.1 only, through `hyper::server::conn::http1` with upgrades. ALPN advertises `http/1.1` only (`tls_listener.rs:131,209`, DT3).
- Each handshake has a 10 s timeout (`tls_listener.rs:30-32`, DT4). Accept errors back off for 1 s and never end the loop (DT5). One `CancellationToken` drains both listeners before `flush_usage` (DT6).
- Handshakes log at debug with the peer address and the TLS version, never cert or key bytes. m263 raises only `data_plane_server::tls_listener` to debug (DT17).
- When the TLS variables are set, `--healthcheck` also connects to the TLS port (`src/main.rs:71`, DT11).
- `orchestrators/compose/docker-compose.engine-tls-data-plane.yml` is composed only when `ENGINE_TLS_ENGINES` lists `data-plane` (DT12):
  - the router gets the cert directory read-only and `pull_policy: build`, so the main-built `:latest`, which has no listener, cannot stand in (DT11);
  - query-router and tenant-control dial `https://data-plane-router-rust:4012`, each with only `ca.pem`;
  - query-router's trust is `NODE_EXTRA_CA_CERTS`, and tenant-control's is `SSL_CERT_DIR=/etc/data-plane-ca:/etc/ssl/certs`;
  - no service sets `SSL_CERT_FILE`, and `NODE_OPTIONS` is untouched;
  - :4012 is never published, and every bind sets `create_host_path: false` (DT13).
- `docker-compose.cloud-minio-tls.yml` lists `/etc/minio-ca:/etc/data-plane-ca:/etc/ssl/certs`. With `CLOUD=1 ENGINE_TLS_ENGINES="minio data-plane"`, tenant-control trusts both CAs. A directory that does not exist is skipped by Go (DT14).
- The key goes to uid 65532 with mode 0400 (DT1). `generate-engine-cert.sh data-plane` does one root `chown` in a throwaway `--network none` alpine container, so this case needs docker.
- No private key is committed. The Rust tests mint their certificates with openssl at test time and fail when openssl is absent (DT15).
- `scripts/verify/m263-data-plane-tls.sh` is the gate (DT16):
  - static checks: opt-in, DT8 byte-identical renders, overlay shape, and trust;
  - live checks (`M263_LIVE=1`): `openssl s_client -verify_return_error -verify_hostname`, a wrong CA, a wrong host name and TLS 1.1 refused, no h2, plain HTTP on :4012 getting no HTTP answer, uid 65532 with the key at 0400, a healthy healthcheck;
  - both of tenant-control's clients over verified TLS: the Kong admin relay and the revoke → evict-verify call;
  - both callers' trust knobs proved by removing them.

## Out of scope (written down, DT18)

- **Kong** stays on plaintext :4011. Its upstream TLS needs the CA entity and `tls_verify: true`, in its own window.
- **nano** and **one** editions stay plaintext and are unsupported with this overlay.
- The **monolith** (`docker-compose.monolith.yml`): make stops with an error when `ENGINE_TLS_ENGINES=data-plane` is combined with any `COMPOSE_FILE` other than `docker-compose.yml` (`orchestrators/makes/00-config.mk`).
- **helm** (`deploy/helm`) and **fly** are not touched.
- The **VM** changes nothing. No b2b VM compose, env or container changes under this ADR. Nothing goes to main before the G1 shadow window ends (2026-10-30 23:52Z at the earliest).

## Alternatives considered

- **Hard cutover on :4011**: Kong has no CA for the hop, so every Kong route to the data plane would break in the same change. Accept mode lets each caller move on its own.
- **A TLS sidecar (stunnel/nginx) in front of :4011**: it adds a component, and the hop from the sidecar to the router stays plaintext inside the pod network (rung 6/7, a new dependency).
- **`axum-server` with rustls**: a new dependency whose default features pull in aws-lc-rs. hyper and hyper-util are already in the tree.
- **`SSL_CERT_FILE` for tenant-control**: it replaces Go's system bundle and breaks the public JWKS, webhook and CMEK calls (ADR 0030 context).

## Consequences

- With the overlay on, a caller missing its trust knob fails at its first data-plane call. m263 proves this for both callers. tenant-control's evict-verify is best-effort and fails with only a warn line; the key cache TTL bounds that.
- An operator's `RUST_DATA_PLANE_URL` in the host env or `.env` overrides the overlay's https default, which keeps that caller on plaintext without a signal. m263 checks the rendered default only.
- engine.pem lasts 397 days and both callers verify it. To renew, re-run the cert script, then recreate data-plane-router-rust.
- Reversal is dropping `data-plane` from `ENGINE_TLS_ENGINES` and recreating the router and its two callers. No data changes.
- Open follow-ups: Kong's hop, require mode (closing :4011 to the signing callers), and a VM rollout in its own window.
