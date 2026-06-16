# Data-plane cutover status (Phase 7 / D6)

The TypeScript→Rust data-plane cutover follows **shadow → parity → cutover**, and
deletion is gated (CLAUDE.md). This tracks where the live demo stands.

## State: bypass is PRODUCTION-READY; app flip is the remaining (out-of-band) step

| Layer | Status |
|---|---|
| Rust `/data/v1` (query, schema, DDL, graph, masks, automations, realtime via outbox) | ✅ feature-complete, parity-gated |
| `DATA_PLANE_BYPASS_ENABLED` | ✅ **default ON** — the Kong `/data/v1` route is live |
| Kong `/data/v1` route (key-auth + ip-restriction, two-key app auth) | ✅ live |
| Shadow parity (direct Rust port) | ✅ `m31-bypass-shadow` |
| **Cutover parity (through Kong, app's real mount)** | ✅ **`m36-cutover-parity`** — list/get/aggregate row-identical to `/query/v1` |
| query-router / permission-engine | ✅ **kept as the fallback — NOT deleted** |
| **App flips its base path `/query/v1` → `/data/v1`** | ⏳ pending (osionos-side change) |

## Performance — the cutover is FASTER than the legacy path

Benchmark (40 reqs, aggregate through Kong, app's live mount):

| Path | Before caches | After caches |
|---|---|---|
| `/data/v1` (Rust cutover) | 358 ms/req | **8 ms/req** |
| `/query/v1` (TS legacy) | 40 ms/req | 40 ms/req |

The bypass originally re-ran the Argon2id key-verify (a tenant-control round-trip)
**and** the mount resolution (an adapter-registry round-trip) on *every* request,
making it slower than the door it replaces. Two short-TTL caches in the data plane
(`verify_cache` api-key→identity, `mount_cache` (tenant,db_id)→DSN, both
`DATA_PLANE_VERIFY_CACHE_TTL_MS`, default 30 s — matching the query-router) fix
that: the cutover door is now **~5× faster** than legacy. Credential events evict
both caches so no stale view survives: rotation (`/v1/admin/rotate`) drops
`mount_cache` (gap-G8/S2 stale-DSN guarantee) and `verify_cache`; key revocation
at tenant-control calls `/v1/admin/evict-verify` so a revoked key is rejected on
its **next** request, not after the 30 s TTL (Track-2 B3, gate `m50-rotate-revoke`).

## Field masks (Track-2 B2) — logic ready, flip gated on the app cutover

The Rust data plane applies ABAC field masks to user-identity responses
(`apply_field_mask`, abac.rs — 9 unit tests; api-key callers are scope-based and
unmasked, matching the query-router). It is behind `DATA_PLANE_APPLY_MASKS`
(default **false**) ON PURPOSE: the query-router still masks, and the app still
calls `/query/v1`, so the legacy door is the single masker during the transition.
Flipping it to `1` is part of the SAME app-side cutover below — when the app
moves to `/data/v1`, the query-router is bypassed and the Rust plane becomes the
masker, so the flip lands with the base-path flip (not before, or both doors mask
redundantly). m36 (api-key path) is unaffected by the flag either way.

## The remaining step (app-side, deliberately not done here)

The osionos app calls `/query/v1/<dbId>/tables/<table>` with a `{op, …}` body in
`apps/osionos/app/src/features/second-brain/baas/*`. The cutover flips that to the
`/data/v1/query` route with a `{db_id, operation:{op, resource, …}}` body. That is
an **osionos submodule change** (its own branch/review per CLAUDE.md), not a BaaS
change — so it is intentionally left to a dedicated app PR. The BaaS side is ready
and proven: `make verify-m36` is the green light.

## Deletion gate (still CLOSED — do not delete TS)

Deleting query-router/permission-engine requires ALL of: m18 live traffic on Rust
with the app actually flipped, sustained shadow parity, and CI green with forward
routing. Until the **app flip** above ships and soaks, the TS path stays as the
fallback. `make verify-m36` proves readiness; it does **not** authorize deletion.

## Roll back

`DATA_PLANE_BYPASS_ENABLED=0` removes the `/data/v1` routes (the app is unaffected —
it still uses `/query/v1`).

## Orchestrator cutover (Track-2 A) — FLIPPED, the −262 MiB is realized

The six Node orchestrators (log/email/session/newsletter/gdpr/outbox-relay) are
folded into ONE Go binary (`cmd/orchestrator`). Cutover executed 2026-06-13:

| Item | Status |
|---|---|
| Consolidated Go binary runs all 6 sub-services | ✅ live (9 MiB RSS, health green) |
| **Footprint win** | ✅ **REALIZED: orchestrator 9 MiB carries all 6 vs the Node six's ~300 MiB = −~290 MiB** |
| Sub-service unit tests | ✅ all 6 green; A3 Mongo projector driver-backed + 9 tests |
| Response parity (envelope + bigint-string ids) | ✅ `internal/orchestrator/envelope` — gate **m48** (newsletter byte-parity) |
| session/gdpr | ✅ the Go ports SERVE where the Node services 500 ("permission denied for schema session") — the cutover FIXES bugs (m48) |
| **Kong flip (A4)** | ✅ **DONE** — kong.yml routes /logs /sessions /newsletter /gdpr /email → `orchestrator:3026` (log/session namespaced); gate **m49** through-Kong green |
| **Node retirement (A5)** | ◑ **quarantined** to `profiles:[legacy-node]` (not started by default) + removed from the editions → the win is the DEFAULT. The SOURCE (`src/apps/{...}`) is KEPT — deletion is the post-soak, irreversible final step. |
| ProductMode | ✅ `enabled` (the orchestrator is the live path) |

Trust: the orchestrator's raw-header `requireUser` reads Kong's injected
`X-User-Id` (the same JWT→header pre-function every authenticated route uses) —
identical to the live adapter-registry-go model. **Rollback** (fully reversible):
start `COMPOSE_PROFILES=…,legacy-node` and revert the five kong.yml `url:` swaps.
The production soak + the `src/apps/{log,email,session,newsletter,gdpr}-service`
+ `outbox-relay` source deletion remain the operator's final A5 step.
