# 06 — SaaS layer: quotas, rate limits, usage metering, plan enforcement

> What turns a multi-tenant platform into a *sellable* product. Today `plan` is stored and ignored; rate-limiting is per-IP; nothing is metered. This is independent of the data-plane work (02–05) and can proceed in parallel.

## Problem

- **`plan` is decorative.** `tenants.plan` exists (migration 032; provision sets `free`/`pro`) but **nothing enforces it** — no feature gating, no limits.
- **Rate limiting is per-IP, not per-tenant.** Kong `rate-limiting` plugins on routes use `limit_by: ip`. A tenant behind one IP can be throttled by a neighbour; a tenant across many IPs is unlimited. Wrong axis for SaaS.
- **No usage accounting.** Queries, rows, storage, function invocations, realtime connections, OLAP minutes — none are counted. So no billing, no fair-use, no abuse detection.
- **No isolation ceilings.** A tenant can open unbounded pool connections to a registered DB; OLAP (05) is GB-RAM with no per-tenant cap.

## Target

1. **Plans define limits** (a `plans` table or config): requests/min, rows/query, storage, function invocations, realtime conns, OLAP enablement, max mounts, max API keys.
2. **Per-tenant rate limiting** at the gateway/edge, keyed by the verified tenant (not IP).
3. **Usage metering** — every billable event counted, aggregated per tenant per period, queryable + exportable for billing.
4. **Enforcement** — limits checked cheaply on the hot path; over-limit → `429`/`402` with a clear machine code; soft (warn) vs hard (block) thresholds.
5. **Billing hooks** — usage records + plan changes emit events a billing system (Stripe, etc.) can consume.

## Design

### 1. Plans & limits (control plane, Go)

A `plans` table (or a versioned config) mapping `plan → limits`. The provision/tenant model gains the plan; a `GET /v1/plans` + `PATCH /v1/tenants/:id` (plan change) round it out. Limits are a typed struct, not magic numbers scattered in code.

### 2. Per-tenant rate limiting

The tenant identity is already resolved at the edge (api-key → `VerifyKey` → slug; signed envelope → tenant). Two options:

- **Kong with a tenant key** — set `rate-limiting` `limit_by: header` keyed on `X-Baas-Tenant-Id` (injected by the api-key middleware *before* the limit runs). Cheapest; Kong-native.
- **A token-bucket in the query-router / a small Go limiter** backed by Redis (already in the stack) — keyed by tenant + plan, supporting different limits per operation class (read vs write vs OLAP). More flexible; needed for plan-aware limits.

Recommendation: **Redis token-bucket keyed by tenant+class**, consulted in the query-router (and other services) via a shared `@mini-baas/common` guard, with plan limits loaded from the control plane (cached). Kong per-IP stays as a coarse DoS guard.

### 3. Usage metering

A lightweight, async meter (don't slow the hot path):

- Each service emits a **usage event** (`tenant, metric, qty, ts`) — reuse the existing **outbox / Redis Streams** pipeline (already powering webhooks/realtime). A Go **metering consumer** aggregates into `tenant_usage(tenant, metric, period, qty)`.
- Metrics: `query.count`, `query.rows`, `write.rows`, `olap.seconds`, `storage.bytes`, `function.invocations`, `realtime.connection.seconds`, `egress.bytes`.
- `GET /v1/tenants/:id/usage?period=…` returns the aggregates; an export feeds billing.

### 4. Enforcement on the hot path

- A `@mini-baas/common` `QuotaGuard` consulted after auth, before the operation: check the relevant counter/bucket; over-limit → `429 quota_exceeded` (rate) or `402 plan_limit` (plan feature) with `{ limit, used, reset_at }`.
- Cheap: counters in Redis, plan limits cached, decisioned in microseconds. Fail-open vs fail-closed is a per-metric policy (rate → fail-closed; metering → fail-open, never lose a request to a meter outage).

### 5. Plan-gated features

- OLAP context (05) requires a plan that allows it (and accounts `olap.seconds`).
- `schema_per_tenant` / `db_per_tenant` isolation, max mounts, functions, webhooks — all plan-gated. The provision orchestrator refuses what the plan forbids.

## Slices

1. **S1 — Plans + limits model** (Go control plane) + `plan` enforcement in provision (reject over-plan mounts/keys).
2. **S2 — Per-tenant rate limit** (Redis token-bucket in `@mini-baas/common`, tenant+class keyed) — wired into the query-router first.
3. **S3 — Usage metering** via the outbox → Go consumer → `tenant_usage`; `GET …/usage`.
4. **S4 — QuotaGuard** on the hot path (429/402) + soft/hard thresholds.
5. **S5 — Billing hooks** — usage + plan-change events to an outbound webhook/queue.

## Verification

- Live: a tenant on `free` hitting the read limit gets `429` with reset info; a `pro` tenant doesn't.
- A burst of queries increments `tenant_usage.query.count`; `GET …/usage` matches.
- Provision refuses a 4th mount on a 3-mount plan with `402`.
- Metering is **async** — verify a meter outage doesn't drop or slow requests (fail-open).

## Risks

- **Hot-path cost** — quota checks must be O(1) Redis ops with cached limits; benchmark under load.
- **Metering accuracy vs availability** — exact billing wants no double-count and no loss; the outbox gives at-least-once → the consumer must dedupe (idempotency key per event).
- **Multi-service consistency** — every entry point (query-router, mongo-api, storage, functions, realtime) must emit usage + honor quotas; centralise in `@mini-baas/common` so it's one implementation.

## Status & live-flip readiness (as of v1.2.0, 2026-06-14)

All three pipeline stages are **landed, gate-backed, and flag-gated OFF = byte-parity** (nothing
meters/enforces/bills until the operator flips the flags). The implementations live in the Go
control plane's `internal/metering` package (sub-services on the orchestrator, like the ported Node
services), consuming the FROZEN B1 envelope (`store.go`) and the `public.tenant_usage` aggregate
(migration 040).

| Stage | What landed | Flag(s), default OFF | Gate |
|---|---|---|---|
| **B1 metering** (S3) | counters → `usage.events` Redis stream → idempotent UPSERT into `tenant_usage`; `GET /v1/tenants/{id}/usage`; emitters for storage/realtime/functions | `DATA_PLANE_METERING` · `METERING_INGEST` (+ per-plane) | m74–m79 |
| **B2 quota enforce** (S4) | `QuotaGuard` sums `tenant_usage` vs the tier `limits.quota` (packages.json) → Redis `quota:over`; data plane returns **402** off a cheap snapshot (no hot-path DB/Redis) | `QUOTA_ENFORCEMENT` · `DATA_PLANE_QUOTA_ENFORCEMENT` | m80 |
| **B3 billing** (S5) | `BillingReporter` pushes one Stripe **meter event per un-reported usage window** (value = window qty, identifier = window idempotency_key), idempotent via the `billing_reported` sent-ledger; tenant→customer map in `tenant_billing` (migration 041) | `BILLING_ENABLED` | m82 |

**To flip B3 billing live** (after B1 is ingesting), set on the orchestrator and onboard tenants:

```
METERING_ENABLED=1
BILLING_ENABLED=1
STRIPE_API_KEY=sk_live_…                      # or sk_test_… in test mode
STRIPE_API_BASE=https://api.stripe.com        # default; the m82 gate points this at a mock
BILLING_METER_QUERY_COUNT=<your meter event_name>   # one BILLING_METER_<METRIC> per billed dimension
# optional: BILLING_REPORT_INTERVAL_MS (default 3600000), BILLING_PERIOD (default month)
```

Then, per paying tenant, insert a `public.tenant_billing` row mapping `tenant_id →
stripe_customer_id` (a tenant with no row, or an empty customer, is simply not billed). The reporter
sends **only** windows of billable metrics for tenants with a customer; Stripe meters must exist with
matching `event_name`s. The `billing_reported` ledger makes re-ticks no-ops, and the Stripe
`identifier` is belt-and-suspenders. **Open (B4):** a self-serve plan-change/dashboard surface that
writes `tenant_billing.plan` + updates the Stripe subscription — B3 is the metering→meter-event half;
the interactive upgrade flow is B4.
