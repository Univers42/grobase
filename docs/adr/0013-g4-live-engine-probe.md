# 0013 — Live engine probe: server version and the pool's own TLS posture

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, P1–P12). Off by default (`DATA_PLANE_PROBE=1`).

## Problem

The descriptor (G4b) tells the UI where a mount points and what TLS its DSN *asks* for. It cannot
say what the engine is or whether the connection the data plane actually holds is encrypted: the
control plane never dials. Those two facts are what the "which database am I on" badge needs.

Reading them is not free:

- **No egress guard on the pool path.** `guard_and_resolve` runs only for the http adapter. A
  probe that opened its own connection would be a new SSRF primitive (P1).
- **The DSN lies about TLS.** MSSQL takes its TLS from the environment, not from `encrypt=` in
  the DSN. The redis crate is built without TLS, so every redis pool is plaintext whatever the
  URL says. A label read from DSN text, or from what the server claims, can show "verified" on a
  plaintext socket (P4).
- **`SharedPool` forwards each method by hand.** A trait-default `probe()` on the wrapped pool
  would answer "unknown" forever, and every raw-pool unit test would still pass (P3).
- **Slow engines.** Mongo's server selection waits up to 30 s; Postgres has no pool timeout (P2).
- **Platform versions are not the tenant's business.** A shared mount's server version is
  platform information (P9). Static `DATA_PLANE_MOUNTS` match any tenant (P8).

## Decision

- **One port method.** `EnginePool::probe() -> EngineProbe { server_version, tls, tls_version? }`,
  default `unknown`. `SharedPool` forwards it; a test proves it (P3).
- **Through the registry only.** The route calls `registry.get_or_create(mount)` and then
  `probe()`, so it dials exactly where `/v1/schema` already dials, and G2's dial guard covers it
  when it lands (P1).
- **The label is the pool's connect setting.** Each adapter records a `TlsPosture` from the
  options it connected with: `verified`, `encrypted` (TLS without verification), `plaintext`,
  `not_applicable` (sqlite), `unknown`. The server may only fill `tls_version`, through a closed
  set (P4). Redis is `plaintext` by construction (since ADR 0024, `rediss://` reports `verified`: `#insecure` is refused before a dial). DynamoDB and http send no request: their label
  comes from the endpoint scheme (P5).
- **Bounded and quiet.** A hard 3 s timeout turns into `unknown`, not an error (P2). Versions go
  through `normalise_version` (digits and dots, at most four parts, 32 chars) so no banner text
  passes (P6). Backend errors keep the fixed public message `map_data_plane_error` already uses (P7).
- **Two layers of rate limiting.** The data plane allows one probe per second per mount
  (`probe:<mount_id>`, P10). The query-router caches per tenant, mount and credential revision for
  at least 30 s, so a revision bump (rotation) is seen at once.
- **The router masks by placement.** `/connect` now returns the descriptor classifier's
  `location`. The router shows the version only for `network`, `file` and `memory`; `platform`
  reads `"platform"`; an absent location (a cred-ref mount, an older registry) reads `"unknown"`.
  Static mounts get 404 (P8, P9).
- **Off by default (P11).** Without `DATA_PLANE_PROBE=1` the data plane registers no route and the
  router answers 404 `engine probe is disabled`. The route sits behind `require_service_auth`.

## What it does not do

- It does not prove the server's certificate chain beyond what the driver checked when the pool
  opened. A pool opened before a TLS config change keeps its old label until it is evicted.
- It does not report MSSQL's negotiated protocol: `sys.dm_exec_connections` needs VIEW SERVER
  STATE, and the probe does not query it.
- Placement is a host heuristic (`isPlatformHost`). A tenant's own LAN box reads as `platform`, so
  its version is hidden. G2 provenance replaces the heuristic; the probe is re-ruled then.

## Evidence

- Port, normalisers and the `SharedPool` forward: `cargo test -p data-plane-core normalise`,
  `cargo test -p data-plane-pool shared_pool_forwards_probe`.
- Per-engine probes and the route: the G4 probe units in `wiki/architecture/multidb-holistic.md`,
  with m246 (static) and m27 (live, a non-empty version per dialing engine).
