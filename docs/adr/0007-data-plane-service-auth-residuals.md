# 0007 — Data-plane inbound service auth: what the shared token still allows

Status: accepted (2026-10-29), rolling out — G1a #62, G1d #70, G1e #71, Go signers #72.
Enforce on the VM needs a human go after ≥ 24 h of shadow with zero `would_deny`.

## Problem

Before G1, `data-plane-server` trusted every `/v1/*` request: the body declared its own
`identity` (`tenant_id`, `roles`) and could carry an `inline_dsn`
(`data-plane-core/src/mount.rs:61`). Anything that could reach `:4011` on the compose network
(an edge function, a compromised sidecar) could run `/v1/admin/raw` as any tenant.

## Decision

- One scheme, reused: the v1 HMAC already used outbound (`X-Service-Auth:
  v1.<ts>.<hmac-sha256(token, "<ts>\n<METHOD>\n<PATH>\n<sha256(body)>")>`). Signers: Rust
  `data-plane-pool/src/service_auth.rs`, Go `serviceauth.SignRequest`, TS `serviceAuthHeaders`,
  shell `scripts/lib/service-auth.sh`. No second scheme.
- `DATA_PLANE_INBOUND_AUTH` = `off` (today's behaviour) / `shadow` (log `would_deny`, serve) /
  `enforce` (401). It covers `/v1/*`; health, metrics, `/v1/capabilities` (unsigned probes in
  m20, m72, m74, m101) and the API-key `/data/v1` path stay outside the layer.
- The body is buffered with a 2 MiB cap (axum's previous default) → 413 before hashing.
- No Kong signer: the Lua sandbox allows only `cjson.safe`, and a Kong signer would sign client
  bodies. `/admin/v1/{migrate,rotate}` move behind tenant-control, which builds the identity and
  signs (G1f).
- Audit lines carry route, outcome and reason — never the body, signature or token.

## Residuals (accepted, not fixed by G1)

1. **One shared token, any identity.** `ADAPTER_REGISTRY_SERVICE_TOKEN` is substituted 23 times
   across 5 compose files (`grep -rhoE '\$\{ADAPTER_REGISTRY_SERVICE_TOKEN[:}-]'
   orchestrators/compose docker-compose*.yml | wc -l`, develop 2026-10-29). Every holder can
   sign a body asserting any tenant and any role: the signature proves "a platform service sent
   this", not "this service may act for this tenant".
   *Since [ADR 0023](0023-data-plane-per-caller-keys.md), under `DATA_PLANE_CALLER_POLICY=enforce`:
   caller class verified; tenant asserted by query-router is trusted.* Each caller signs with its
   own key, the verifying key decides which routes it may reach, and identity and mount must name
   one tenant. Which tenant query-router asserts is still not proven. With the policy `off` (the
   default), this residual stands as written.
2. **Replay inside the skew.** A captured request replays verbatim for `SERVICE_AUTH_SKEW_SECS`
   (default 120, `service_auth.rs:83-92`, `serviceauth.go:75-79`). There is no nonce cache.
   Exposure is limited to someone already reading compose-network traffic.
3. **Inline DSN from any token holder.** `inline_dsn` / `replica_inline_dsn` are still accepted
   from any signed body, so a token holder can point the data plane at an arbitrary DSN. G2's
   dial guard bounds where it can connect; it does not bound who may ask.
   *Since ADR 0023, under enforce: caller class verified; tenant asserted by query-router is
   trusted.* An inline DSN is admitted only on query-router's routes and on tenant-control's
   migrate and rotate. Anywhere else it is refused before resolve or dial.

## Reopen when

- A service that should not act cross-tenant needs the token (e.g. user code, a third-party
  sidecar): move to `v2.<kid>` — one key per caller, and the receiver maps kid → allowed
  identities and routes.
- Traffic between services leaves one host or one trusted network: add a nonce cache (bounded
  by the skew window) or mTLS before that link carries signed requests.
- A caller other than query-router needs `inline_dsn`: restrict it by kid first.
