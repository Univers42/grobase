# 0030 — MinIO serves HTTPS only through one opt-in hard-cutover overlay; no plaintext listener beside it

- Status: proposed. devil ruled PROCEED-WITH-CONDITIONS on 2026-10-30 for the develop overlay (MH1–MH16). Any VM rollout stays BLOCKED (V1–V6).
- Date: 2026-10-30
- Deciders: devil (ruling). Whoever composes `ENGINE_TLS_ENGINES=minio` lives with the outcome.

## Context

- MinIO with `--certs-dir` has no accept mode. Plain HTTP on :9000 and :9001 gets 400. The devil measured this on RELEASE.2025-09-07 before the 2026-10-30 BLOCK, and the spike measured it again (k1b, the Go 400): `wiki/architecture/minio-https-trust-matrix.md`.
- Every client runtime verifies the CA and refuses a wrong one (same doc, L1): Node `NODE_EXTRA_CA_CERTS`, Go `SSL_CERT_DIR`, mc `certs/CAs`, and the temurin `USE_SYSTEM_CA_CERTS=1` + `/certificates` for both iceberg-rest and trino.
- Trino with a wrong CA fails only after 140.7 s of SDK retries. The top-level error does not name TLS (`Failed checking new table's location`), and nothing goes to stdout.
- Kong 3.8 verifies the upstream only with a `ca_certificates` entity plus `tls_verify: true`. Without `tls_verify`, `https://` returns 200 while Kong holds no CA (k1). `lua_ssl_trusted_certificate` is not used for upstream verification (k5).
- Prod publishes `9000:9000` for presigned URLs (`orchestrators/compose/docker-compose.prod.yml:263`). `S3_PUBLIC_ENDPOINT` signs URLs that browsers fetch (`src/apps/storage-router/src/storage/storage.service.ts:106,198-207`). A private CA is not trusted by those clients.
- m195 asserts that minio in prod publishes exactly `["9000->9000"]` (`scripts/verify/m195-prod-overlay-hardening.sh:128`).
- The control-plane makes public HTTPS calls (`internal/sso/jwks.go:63`, `internal/webhooks/delivery.go:65`, `internal/cmek/provider.go:81`). `SSL_CERT_FILE` replaces Go's system bundle, so the private CA would break all of those calls.
- storage-router already sets `NODE_OPTIONS=--max-old-space-size=96` (`orchestrators/compose/base/app-services.yml:252`, gate m185).
- `certs/engine-tls/<engine>/` holds `engine-key.pem` next to `ca.pem` (`scripts/certs/generate-engine-cert.sh:25,144`).
- Unknown when this was written: whether the VM composes the prod overlay or sets `S3_PUBLIC_ENDPOINT`; which off-docker clients (osionos, tenants) consume presigned URLs; whether a Trino S3 retry setting shortens the 140 s.

## Decision

- `orchestrators/compose/docker-compose.engine-tls-minio.yml` is composed only when `ENGINE_TLS_ENGINES` lists `minio`. Without it, both the compose render and the rendered kong.yml are byte-identical to today's (gate m262).
- MinIO serves HTTPS on the same ports, 9000 and 9001. Console :9001 was measured: https 200, plain 400 (MH12). Every in-network endpoint switches in that one overlay, each with its own additive trust knob (MH5): Node `NODE_EXTRA_CA_CERTS`, mc `certs/CAs`, the JVMs `USE_SYSTEM_CA_CERTS=1` + `/certificates`, Go `SSL_CERT_DIR=<ca dir>:/etc/ssl/certs`. No service sets `SSL_CERT_FILE`.
- With `CLOUD=1`, make also composes `docker-compose.cloud-minio-tls.yml`, which moves tenant-control's backup store to https. That file is not an engine overlay, so it is not named `engine-tls-*` (m247 globs those).
- Kong points at `https://minio:9000` with `tls_verify: true`. `render-kong-config.sh` adds the CA entity only when the overlay sets `KONG_MINIO_CA_FILE`, and refuses to render with a missing CA, a private key in its place, or a template without the storage url.
- Trino's healthcheck in the overlay also verifies MinIO with its mounted CA. A wrong CA shows as unhealthy at once instead of failing a query after 140 s (MH9 option i).
- Refusals (MH10), deviation recorded: compose evaluates `${A:+${B:?}}` eagerly (measured, v2.36.0), so the render cannot refuse. MinIO's entrypoint refuses to start, with the reason, when `S3_PUBLIC_ENDPOINT` is set. The refusal happens at start, not at render: `up -d` still exits 0 and the services that depend on MinIO with `service_started` start anyway. The only signals are MinIO's restart loop and its log line. `PROD_FILES` (`make prod-up`) never composes the overlay (gate m262). A hand-written `-f docker-compose.prod.yml` command without `S3_PUBLIC_ENDPOINT` is not refused.
- Host and ops scripts (MH11): phase9 and stack-health-requests work over TLS with the container's public CA. vault-seed skips MinIO and vault-restore refuses before changing anything, each naming the overlay. Upgrade path: copy the CA in with `docker cp` and pass it to mc as `SSL_CERT_FILE` in the helper container.
- Monolith and helm are unsupported (MH15): `docker-compose.monolith.yml` and `deploy/helm` still dial `http://minio:9000` and are not touched. make stops with an error if `ENGINE_TLS_ENGINES=minio` is combined with any `COMPOSE_FILE` other than `docker-compose.yml`.
- `scripts/verify/m262-minio-https.sh` is the gate (MH13). Static checks run on every push; the live legs (`M262_LIVE=1`) run in CI against MinIO built from the commit.

## Alternatives considered

- **Dual listener (plaintext 9000 + TLS beside it)**: MinIO has no flag for it, so it needs a new TLS-terminator component (rung 6/7). It keeps the plaintext hop the G5 item exists to remove, and its second published port fails m195 (`m195:128`). See `.out-of-scope/minio-dual-listener.md`.
- **Hard cutover on the default path**: it breaks presigned URLs for every external client (`prod.yml:263`) and the 4 healthchecks, and nothing on the default path asks for it.
- **Kong `https://` without `tls_verify`**: encrypted, but it trusts any cert (k1). Allowed only if labelled Encrypted, and this overlay does not use it.

## Consequences

- With the overlay on, a missed trust knob fails at the first request, except Trino (140 s). The overlay's gate must catch it (MH9).
- The devil re-ruled the MH10 deviation PROCEED-WITH-CONDITIONS on 2026-10-30: refusing at start still fails closed, and prod cannot compose the overlay. The conditions are R1, the `minio-https` CI job green twice (MH13); R2, MH16 tagged in the gate; R3, console :9001 removed from the unknowns; R4, the start-time refusal recorded above.
- Reversal is dropping `minio` from `ENGINE_TLS_ENGINES` and recreating MinIO and its clients. The data volume is untouched.
- Open follow-ups: the public presigned-URL endpoint under TLS, monolith and helm support, VM rollout V1–V6, and the pre-existing `mc`-in-minio-image bug (`infra/docker/services/minio/tools/create-bucket.sh:27`, `scripts/verify/m159-storage-bucket-scope.sh:76`), which is tracked on its own.
