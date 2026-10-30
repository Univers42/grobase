# 0023 — Data-plane per-caller keys: the verifying key is the caller class

Status: accepted (2026-10-30), shipped behind `DATA_PLANE_CALLER_POLICY=off`. Shadow and enforce
on the VM need a human go after G1 enforce (ADR 0007) has its own window. Devil
PROCEED-WITH-CONDITIONS K1–K14, 2026-10-30.

## Problem

ADR 0007 residuals 1 and 3: the data plane verifies one shared token, held by about nine
services. `functions-runtime`, which hosts tenant code, is one of them
(`orchestrators/compose/base/storage.yml`). Any holder can sign a body that asserts any tenant,
any role and any `inline_dsn`. ADR 0007's "reopen when" condition has fired, because a service
that runs user code holds the token.

The data plane has only two production callers of `/v1/*`:

- **query-router**: query, schema, schema/ddl, transactions, probe, permissions/decide.
- **tenant-control**: admin/migrate, rotate, evict-verify, and the Kong admin relay.

`/v1/admin/raw` has no production caller.

## Decision

- **Implicit kid, v1 wire format unchanged.** query-router signs with
  `DATA_PLANE_KEY_QUERY_ROUTER` and tenant-control with `DATA_PLANE_KEY_TENANT_CONTROL`, each
  with a `_PREV` for rotation. The data plane tries every configured key (shared current/prev,
  then both callers' pairs) without an early exit. The key that verifies is the caller class:
  `query_router`, `tenant_control` or `legacy`. Signers change only their env wiring: each one
  falls back to the shared token when its key is unset.
- **Distinct random keys, minted by `scripts/env/generate-env.sh`** (`openssl rand -hex 32`,
  additive `--topup`, never a `_PREV`). Each key goes to exactly its holder and the data plane.
  `functions-runtime` gets none.
- **One table** (`routes/caller_policy.rs`, `ROUTE_POLICY`) maps each internal route to its
  class and says whether that route may carry `inline_dsn` / `replica_inline_dsn`. The checks
  run in the inbound layer, after G1a and before any handler, in this order:
  1. unsigned → 401
  2. `legacy` → 403
  3. unlisted route → 403
  4. wrong class → 403
  5. non-JSON body → 400
  6. inline DSN where the row refuses it → 403
  7. `identity.tenant_id ≠ mount.tenant_id` → 403

  A refused call never resolves or dials.
- **Inline DSN by route, not by caller.** query-router may send it on its own routes, and
  tenant-control may send it on migrate and rotate. Provisioning (`dataplane.go`
  `ensureSchema`) and the SDK migrate through the relay both need that. `/v1/admin/raw`,
  `/v1/admin/evict-verify` and `/v1/permissions/decide` refuse it. "Inline DSN only from
  query-router" was ruled BLOCK, because it breaks provisioning.
- **`DATA_PLANE_CALLER_POLICY` = `off` (default, no class judged) / `shadow` (log
  `would_deny` with route, class and reason, then serve) / `enforce` (the refusal above).** It
  is independent of `DATA_PLANE_INBOUND_AUTH`. The caller keys are also valid credentials for
  G1a, so turning G1a on never refuses a caller that signs with its own key.
- **Startup refusal (K8).** In every mode, the process refuses to start if a set key is under
  32 bytes or has leading or trailing whitespace (a `_PREV` of `" "` included), because G1a
  accepts the keys even under `off`. Under shadow or enforce it also refuses if either current
  key is unset or any two keys are equal (shared token included). An unset key is fine under
  `off`. The error names the variable, never the value.

## What it proves, and what it does not

It proves the caller **class** (who holds the verifying key), the routes that class may
reach, and that identity and mount name one tenant. It does **not** prove that the tenant
asserted by query-router is the end user's. query-router builds identity and mount from the
same `context.tenantId` (`rust-data-plane.proxy.ts`, `buildIdentity` / `buildMount`). That
tenant is still trusted, as in ADR 0007. query-router also legitimately forwards
`service_role` (the F2 admin bypass), so that role is refused only on admin routes, through
the class table.

While the policy is `off`, the shared token is still accepted everywhere and the security gain
is zero.

## Rejected

- **HKDF from `INTERNAL_SERVICE_TOKEN`.** Every holder can derive every caller key, so it gives
  no separation.
- **Explicit `v2.<kid>` header.** It changes the wire format for two callers. Revisit when a
  third caller appears.

## Residuals

- Replay inside the skew window (ADR 0007 residual 2) is unchanged.
- The functions-runtime process still holds the shared token. Once the policy is `enforce`,
  that token reaches no route in the service-auth group (health, metrics, `/v1/capabilities`
  and the API-key `/data/v1` path were never in it).
- query-router can act for any tenant, because the tenant it asserts is trusted. Binding that
  tenant to the end user needs a claim signed by the edge, and is out of scope here.

## Enforce preconditions

`DATA_PLANE_CALLER_POLICY=enforce` must not be set on any deployment until both hold. Neither
weakens `off` or `shadow`, so the code ships with the policy off.

1. **The admin relay stops accepting the shared token, or gets its own key.** tenant-control's
   `POST /v1/admin/{migrate,rotate}` accepts `INTERNAL_SERVICE_TOKEN` (the `service_token` arm,
   `src/control-plane/internal/tenants/admin_relay.go:69`). It then re-signs the call with the
   tenant-control key (`admin_relay.go:51`, key chosen in `cmd/tenant-control/boot.go:69`).
   functions-runtime holds that token (`orchestrators/compose/base/storage.yml:74`). Under
   enforce, it could therefore drive `/v1/admin/migrate` as `tenant_control` with any
   `inline_dsn`, which is the very class split this ADR makes. The fix is one of two: drop the
   `service_token` arm while the policy is on, or give the relay its own credential. Either fix
   needs its own devil ruling before enforce.

   **Relay half met** (devil PROCEED-WITH-CONDITIONS, 2026-10-30). tenant-control reads the
   same `DATA_PLANE_CALLER_POLICY` the data plane does (`base/control-plane.yml`,
   `docker-compose.monolith.yml`, static check in `m243-data-plane-auth.sh`). It parses the
   value once at boot like `InboundAuthMode::parse` and refuses to start on an unknown value
   (`admin_relay_policy.go`). Under `enforce` the relay never takes the `service_token` arm,
   `INTERNAL_SERVICE_TOKEN_PREV` included, and answers 401 naming the policy. The apikey arm
   still serves, also when both credentials are sent. Under `shadow` the token still relays
   and logs one `admin relay: would_deny` line per request (route, arm, never the token).
   Evidence: `admin_relay_policy_test.go` and the relay legs of `m243-caller-policy-live.sh`.

   **Still open: the provision door.** `POST /v1/provision` (`handler.go:83`,
   `requireServiceToken`) calls `reconcileSchema` (`provision.go:128`), which calls
   `ensureSchema` (`dataplane.go:62-81`). That signs `/v1/admin/migrate` as `tenant_control`
   with the caller's `connection_string` as `inline_dsn` (`dataplane.go:76`). The statement
   is fixed (`CREATE SCHEMA IF NOT EXISTS <sanitized schema>`), so it cannot run arbitrary
   SQL. It can still make the data plane dial any DSN as `tenant_control`. This door needs
   its own devil ruling before enforce. Before any VM enforce: a VM shadow window with zero
   `would_deny` lines, then a fresh ruling together with precondition 2.
2. **`IDENTITY_HEADER_MODE=strict` on every service that reads identity.** In compat mode,
   `src/libs/common/src/identity/request-identity.ts:41` trusts raw `x-baas-*` headers. Compat
   is the default whenever `NODE_ENV` is not `production` (`request-identity.ts:364`). A caller
   class proves nothing if the identity it carries can be forged one hop earlier.

## Evidence

- `cargo test --workspace`: `caller_policy_tests.rs`, `caller_policy_router_tests.rs` (every
  route under each class, the rotation window, `off` parity, a refused inline DSN with zero TCP
  accepts) and `caller_keys_tests.rs` (K8).
- `go test ./...`: `TestDataPlaneSigningKeyPrefersTheTenantControlKey` and
  `TestAdminRelaySignsTheDataPlaneHopWithItsOwnKey`.
- jest: "signs with DATA_PLANE_KEY_QUERY_ROUTER when set".
- `scripts/verify/m243-data-plane-auth.sh`: static in CI. With `M243_LIVE=1` it runs the
  forged-identity arms against scratch containers under enforce (nightly).
