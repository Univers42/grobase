# MinIO HTTPS — client CA-trust matrix (G5 lift conditions L1–L5)

*Research spike for the devil's BLOCK on MinIO HTTPS (2026-10-30). It measures L1 and
inventories L3, sets out the inputs to L2 without deciding, and records L4/L5. Nothing
here switches MinIO to HTTPS on any default path. The devil decides.*

Measured 2026-10-30 on `develop` 3826dfbf with local images: `grobase-minio:latest`
(RELEASE.2025-09-07), `grobase-storage-router:latest` (Node 20.20.2, `@aws-sdk/client-s3`
3.1029.0), `grobase-mc:latest` (RELEASE.2025-04-08), `grobase-trino:latest` (483, temurin
25-jre-alpine), `grobase-iceberg-rest:latest` (temurin 23-jre-alpine), `grobase-kong:latest`
(3.8.0 OSS). Go is `golang:1.26.9` and runs on `distroless/static-debian12:nonroot`, the
control-plane's runtime base.

Caveat: this matrix covers one throwaway MinIO on one isolated docker network. It has one
leaf with SANs `minio, mini-baas-minio, localhost, 127.0.0.1`, signed by a throwaway CA
(`CN=spike-ca`), plus one unrelated CA (`CN=wrong-ca`) as the wrong-CA case. It does
**not** cover:
- the VM or any live stack;
- CA rotation or leaf renewal on a running client: JVM truststores are built once at
  container start, and Node reads `NODE_EXTRA_CA_CERTS` once at process start;
- presigned-URL consumers outside docker (browsers, tenant SDKs);
- the monolith compose file;
- Kong's other services;
- performance (handshake cost);
- mTLS.

The Go row ran the real `store_minio*.go` files copied into a scratch module, not the whole
control-plane binary. The JVM rows used a minimal Trino with only the iceberg catalog.

## Fixture

The leaf follows `scripts/certs/generate-engine-cert.sh` `issue_leaf`: `CA:FALSE`, `serverAuth`,
397 days there and 2 days here. That script has no `minio` case today, so a real rollout
adds one. MinIO starts as `server /data --certs-dir /certs` with `public.crt`,
`private.key` and `CAs/ca.crt`. Network `minio-spike-net`, container `minio-spike-minio`
with alias `minio`, and buckets `baas` and `iceberg` created through mc. Every
`minio-spike-*` container, network and image was removed at the end (see Cleanup).

## L1 — CA-trust matrix

One verified HTTPS request (or more) per runtime, against `https://minio:9000`.

| Runtime (real caller) | How the CA is trusted | Verified OK | Wrong CA refused | No CA (default bundle) |
|---|---|---|---|---|
| Node: storage-router, `@aws-sdk/client-s3` S3Client (`storage.service.ts:90`) | `NODE_EXTRA_CA_CERTS=/ca/ok.crt` (adds to the bundled roots). Alternative: `NODE_OPTIONS=--use-openssl-ca` + `SSL_CERT_FILE` | yes: ListBuckets + PutObject + GetObject | yes: `UNABLE_TO_VERIFY_LEAF_SIGNATURE` | refused (same error) |
| Go: control-plane backup `NewMinIOStore` (`store_minio.go:49`), default `http.Client` | `SSL_CERT_FILE=/ca/ok.crt` (replaces the system bundle), or `SSL_CERT_DIR=/ca/dir:/etc/ssl/certs` (adds to it). `https://` prefix on `MINIO_ENDPOINT` selects TLS (`store_minio.go:50`) | yes: boot self-check PUT+GET+DELETE | yes: `x509: certificate signed by unknown authority` | refused (same) |
| mc: `grobase-mc` (`lakehouse.yml:152`), and pg-backup (`ops.yml:27`) | `<config-dir>/certs/CAs/<ca>.crt` (`~/.mc/certs/CAs` by default), or `SSL_CERT_FILE` | yes: `mb` + `ls` | yes: `x509: certificate signed by unknown authority`, exit 1 | refused, exit 1 |
| JVM: iceberg-rest S3FileIO (`lakehouse.yml:82`) | temurin's inherited `ENTRYPOINT /__cacert_entrypoint.sh`: `USE_SYSTEM_CA_CERTS=1` + CA mounted in `/certificates/*.crt`. Non-root, so it copies cacerts to a temp truststore and appends `-Djavax.net.ssl.trustStore` to `JAVA_TOOL_OPTIONS` | yes: CREATE TABLE wrote metadata to `s3://iceberg/` | yes: `PKIX path building failed` (500 to Trino) | refused: `PKIX path building failed` (j6, 3.1 s) |
| JVM: trino native-s3 (`iceberg.properties:12`) | the same temurin entrypoint mechanism (the image's ENTRYPOINT is `/__cacert_entrypoint.sh`) | yes: INSERT 1 row, SELECT returned `42`; parquet + metadata objects listed in MinIO | yes: root cause `SunCertPathBuilderException: unable to find valid certification path`, but only after **140.7 s** of SDK retries (j3c) | refused: `Failed checking new table's location` (j4) |
| Kong 3.8 OSS DB-less (`kong.yml:343`) | a top-level `ca_certificates:` entity (PEM inline) + `tls_verify: true` + `ca_certificates: [<id>]` on the service | yes: 200 | yes: 502, `upstream SSL certificate verify error: (20:unable to get local issuer certificate)` | **not verified by default**: `https://` with no `tls_verify` gives 200 even though Kong holds no CA |

Kong in detail (`kong-case.sh`, one DB-less Kong per row, `GET /storage/v1/minio/health/live`):

| Case | Result |
|---|---|
| k1 `url: https://minio:9000`, no `tls_verify` | 200. Encrypted but unverified: Kong trusts any cert |
| k1b `url: http://minio:9000` (today's kong.yml) against the TLS listener | 400 (plain HTTP to an HTTPS port) |
| k2 `tls_verify: true` + spike-ca entity | 200 |
| k3 `tls_verify: true` + wrong-ca entity | 502, verify error 20 |
| k4 `tls_verify: true`, no CA entity | 502, verify error 20 |
| k5 `tls_verify: true` + `KONG_LUA_SSL_TRUSTED_CERTIFICATE=system,/ca/ok.crt` | 502. That setting does **not** feed upstream verification, so the CA entity is required |
| k6 `tls_verify: true` + spike-ca, `url: https://<minio IP>:9000` (not in SANs) | 502, `upstream SSL certificate does not match "172.20.0.2"`. Kong checks the hostname too |

JVM detail:
- iceberg-rest's createNamespace never touches S3, so `CREATE SCHEMA` passes in every case.
  The first S3 hop is `CREATE TABLE`.
- Trino with a wrong CA fails slowly: `CREATE TABLE` returned after 140.7 s. The
  top-level message (`Failed checking new table's location`) does not name TLS, and nothing
  was logged to stdout. Only the query's `failureInfo` cause chain shows
  `SunCertPathBuilderException`. iceberg-rest fails in 3.1 s and logs `PKIX path building failed`.
- The plaintext Go client against the TLS port returns `MinIO PUT 400: Client sent an HTTP
  request to an HTTPS server`, the same no-accept-mode fact as the verdict.

Commands (from the scratch harness; `W` is the scratch dir holding certs, `pw`, `mc.env`):

```sh
# Node
docker run --rm --network minio-spike-net -e S3_ENDPOINT=https://minio:9000 -e S3_SECRET_KEY="$(cat pw)" \
  -e NODE_EXTRA_CA_CERTS=/ca/ok.crt -v $W/s3probe.cjs:/app/s3probe.cjs:ro -v $W/spike-ca.crt:/ca/ok.crt:ro \
  --entrypoint node ghcr.io/univers42/grobase-storage-router:latest /app/s3probe.cjs
# -> OK buckets=baas,iceberg get=ok-node     (wrong CA -> FAIL UNABLE_TO_VERIFY_LEAF_SIGNATURE)
# Go (probe = store.go + store_minio*.go + a 10-line main calling backup.NewMinIOStore)
docker run --rm --network minio-spike-net -e MINIO_ENDPOINT=https://minio:9000 -e MINIO_ROOT_PASSWORD="$(cat pw)" \
  -e SSL_CERT_FILE=/ca/ok.crt -v $G/probe:/probe:ro -v $W/spike-ca.crt:/ca/ok.crt:ro \
  --entrypoint /probe gcr.io/distroless/static-debian12:nonroot
# -> OK self-check PUT+GET+DELETE            (wrong CA -> x509: certificate signed by unknown authority)
# mc
docker run --rm --network minio-spike-net --env-file $W/mc.env -v $W/mcok:/cfg \
  ghcr.io/univers42/grobase-mc:latest --config-dir /cfg ls local
# -> 0B baas/ 0B iceberg/                    (mcbad/certs/CAs/wrong-ca.crt -> exit 1, unknown authority)
# JVM: iceberg-rest + trino, each with -e USE_SYSTEM_CA_CERTS=1 -v $W/jvm/ok:/certificates:ro,
# iceberg CATALOG_S3_ENDPOINT / trino s3.endpoint = https://minio:9000, then via /v1/statement:
#   CREATE SCHEMA ... ; CREATE TABLE iceberg.s_j1.t (x integer); INSERT ... VALUES (42); SELECT x
# -> OK [] / OK [] / OK [[1]] / OK [[42]]
# Kong
W=$W kong-case.sh k2-verify-ok https://minio:9000 true ok     # -> HTTP 200
W=$W kong-case.sh k3-verify-wrong https://minio:9000 true bad # -> HTTP 502
```

Prior art already in the repo: `scripts/verify/m242-monitored-backup-restore.sh:38-47` runs
pg-backup's mc against `grobase-minio --certs-dir`, with the CA at `/root/.mc/certs`.

## L3 — host-side and off-network callers of :9000 / :9001

A static grep over the repo (excluding `.git`, `node_modules`, `vendor` and lockfiles):
`grep -rnIE '((127\.0\.0\.1|localhost|0\.0\.0\.0):900[01]\b|:9000:9000|MINIO_(API_|CONSOLE_)?PORT)'`
returned 24 lines, plus a bare-`9000` sweep of `Makefile scripts orchestrators deploy`. The
grep is static: it misses anything that builds the URL at runtime from `MINIO_API_PORT`
without the literal.

### Ports published off the docker network

| file:line | What it is |
|---|---|
| `orchestrators/compose/base/storage.yml:28-29` | publishes `${ENGINE_BIND_ADDR:-127.0.0.1}:9000` (S3) and `:9001` (console) to the host |
| `orchestrators/compose/docker-compose.prod.yml:263` (comments `:21`, `:47`) | prod publishes **`0.0.0.0:9000`**: the S3 API for presigned URLs. Any off-host client of a presigned URL is a MinIO TLS client |
| `orchestrators/compose/docker-compose.monolith.yml:1840-1841` | monolith publishes `0.0.0.0:9000` and `:9001` with no bind address |
| `src/apps/storage-router/src/storage/storage.service.ts:106` + `app-services.yml:266`, `monolith.yml:1508` | `S3_PUBLIC_ENDPOINT` signs the presigned URLs browsers fetch. Under TLS that endpoint needs a cert those clients trust, and a private CA is not one |

### Host-side callers (run on the host, dial loopback)

| file:line | What it is |
|---|---|
| `scripts/test/phase/phase9-storage-operations-test.sh:21` | `MINIO_ENDPOINT` default `http://127.0.0.1:9000`: the host test suite talks S3 directly |
| `infra/docker/services/minio/README.md:37,71,74,77,82,87,93` | operator docs: `mc alias set local http://localhost:9000`, `aws --endpoint-url http://localhost:9000`, console `http://localhost:9001`, `curl .../health/live\|ready` |

### In-container loopback (docker exec, or the image's own healthcheck). Plaintext is refused under TLS

| file:line | What it is |
|---|---|
| `orchestrators/compose/base/storage.yml:14` | compose healthcheck `curl -fsS http://localhost:9000/minio/health/live` (exit 22 under TLS, measured) |
| `infra/docker/services/minio/Dockerfile:45` | image HEALTHCHECK, the same curl |
| `orchestrators/compose/docker-compose.monolith.yml:1830` | monolith healthcheck, the same curl |
| `deploy/helm/mini-baas/values.yaml:530` | helm probe, the same curl |
| `scripts/ops/stack-health-requests.sh:101` | `docker exec $PROJECT-minio curl --aws-sigv4 ... http://localhost:9000/` |
| `infra/docker/services/minio/tools/create-bucket.sh:27` | `docker compose exec minio mc alias set local http://localhost:9000`. Already broken: the image has no `mc` (`command -v mc` → none) |
| `scripts/verify/m159-storage-bucket-scope.sh:76` | `docker exec mini-baas-minio sh -c "mc alias set lo http://localhost:9000 ..."`. Same pre-existing no-`mc` issue |

### Host-scripted, in-network by container name (they switch with the in-network set)

| file:line | What it is |
|---|---|
| `scripts/ops/vault-seed.sh:170` | `MC_HOST_seed=http://…@mini-baas-minio:9000` |
| `scripts/ops/vault-restore.sh:512` | the same |

### Not callers (they only reserve or assert the port; a TLS-only change leaves them alone)

| file:line | What it is |
|---|---|
| `scripts/ops/resolve-ports.sh:37-38` | port allocation defaults |
| `scripts/ci/preflight-check.sh:144` | port-free check |
| `scripts/verify/m195-prod-overlay-hardening.sh:117-130` | asserts prod publishes exactly `9000->9000`. A dual listener's extra port fails this gate |
| `src/data-plane-router/crates/data-plane-pool/src/http/mod.rs:121` | a parser test literal, not MinIO |

The in-network set, for L2 scope: `kong.yml:343`, `app-services.yml:265`, `lakehouse.yml:82,152`,
`iceberg.properties:12`, `ops.yml:27`, `docker-compose.cloud.yml:70` (control-plane
`MINIO_ENDPOINT`), `pg-backup/scripts/entrypoint.sh:20,57`, and the monolith copies at
`monolith.yml:386,500,1507,1909`. Scratch-MinIO verify scripts (m77, m95, m192, m209, m228)
start their own plaintext MinIO and are unaffected, as long as the image default stays
plaintext.

**Count:** 4 off-network exposures (3 published-port lines and the presign endpoint),
2 host-side caller sites (phase9, plus the README with 7 lines), 7 in-container loopback
sites, 2 host-scripted in-network sites, 4 non-callers.

## L2 inputs — not a decision

| | Hard-cutover overlay (one overlay flips every endpoint to `https://minio:9000`) | Dual listener (plaintext 9000 kept, TLS beside it) |
|---|---|---|
| What L1 implies | Each of the 6 runtimes needs its own trust knob in the same overlay: `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`/`SSL_CERT_DIR`, mc `certs/CAs`, `USE_SYSTEM_CA_CERTS=1` + `/certificates` ×2, and the Kong CA entity + `tls_verify`. Every knob was measured to work, and every runtime refuses a wrong CA, so a missed knob fails loudly at first request rather than silently. Trino is the exception: it fails slowly (140.7 s) and does not name TLS | MinIO has no accept mode (verdict, and the k1b/Go 400s above), so the second listener is not a MinIO flag. It is a new component (a TLS terminator in front of, or beside, MinIO): rung 6/7, and it needs its own justification. Clients migrate one at a time with the same knobs |
| What L3 implies | Must also change 4 healthchecks (`storage.yml:14`, `Dockerfile:45`, `monolith:1830`, `helm:530`) to `https://localhost` with `--cacert`, `stack-health-requests.sh:101`, `phase9:21`, the vault-seed/restore `MC_HOST_seed`, and the README. Prod `0.0.0.0:9000` presigned URLs switch to TLS: external clients need a publicly trusted cert, or presign must move behind the WAF | Healthchecks and host callers keep working on plaintext 9000. But m195 asserts exactly one published minio port, and a TLS port beside plaintext keeps the plaintext hop: the G5 goal is met only for migrated clients |
| Kong | `tls_verify` + CA entity is possible in DB-less 3.8 (L4 below). The PEM must be rendered into kong.yml by `render-kong-config.sh` | same Kong change, pointed at the TLS port |

## L4 — Kong verifies upstream

Measured: yes. Kong 3.8.0 OSS, DB-less, `_format_version: "3.0"`: a top-level
`ca_certificates: [{id, cert}]` entity plus `tls_verify: true, ca_certificates: [<id>]` on
the `storage` service verifies the chain (k2 200, k3/k4 502) and the hostname (k6 502).
`lua_ssl_trusted_certificate` is not consulted for upstream TLS (k5). Without `tls_verify`,
an `https://` upstream is encrypted but unverified (k1): label that hop Encrypted, never
Verified. Implementation note: the CA PEM has to be inlined into the declarative file, so
the render step must inject it. Kong reads no CA file path for this.

## L5 — setpriv in grobase-minio

Measured: the shipped image's `/bin/setpriv` is BusyBox (`-> /bin/busybox`, `unrecognized
option: reuid`). `engine-tls/drop-entrypoint.sh:34` refuses it: `minio TLS: this image's
setpriv cannot drop root (BusyBox?); rebuild the image`, exit 1.

Minimal Dockerfile change, **not committed** (`infra/docker/services/minio/Dockerfile:34`):

```dockerfile
RUN apk add --no-cache ca-certificates curl setpriv \
```

A throwaway `FROM grobase-minio` + `apk add --no-cache setpriv` image gives util-linux
`/usr/bin/setpriv` (34,712 bytes; the image stays 124 MB) and
`setpriv --reuid=1001 --regid=1001 --clear-groups id` → `uid=1001(minio) gid=1001(minio)`.

Two more changes a rollout needs, also not committed:
- a `minio)` case in `drop-entrypoint.sh` that lays out `$dst/certs/{public.crt,private.key,CAs/ca.crt}`
  and appends `--certs-dir $dst/certs`. Measured in a scratch copy: PID 1 runs as uid 1001,
  the key is `-rw------- 1001 1001` on tmpfs, and verified HTTPS returns 200;
- the healthcheck: `curl -fsS http://localhost:9000/...` exits 22, while
  `curl -fsS --cacert /run/engine-tls/certs/CAs/ca.crt https://localhost:9000/...` exits 0.

## Cleanup

`docker ps -a --filter name=minio-spike-`, `docker network ls --filter name=minio-spike-` and
`docker images minio-spike-l5` all returned nothing after teardown. No `mini-baas_*`
volume, `:8443` or VM was touched.
