# 01 — Gap analysis: what is missing for a true layer-swappable BaaS

> [00 Overview](00-overview.md) · **01 Gap analysis** · [02 Layer & edition model](02-layer-edition-model.md) · [03 Control plane](03-control-plane.md) · [04 Data plane](04-data-plane.md) · [05 Orchestration & roadmap](05-orchestration-observability-roadmap.md)

The platform works. The question this doc answers is narrower and harder: **what is missing so that the BaaS can change its layers according to need** — pick an edition, swap an engine, choose an isolation model, promote a plane from shadow to live — *without bespoke wiring each time*.

Each gap below is grounded in a concrete file. Status legend: ✅ done · 🟡 partial · ❌ missing.

---

## Scorecard

| # | Gap | Status | Plane | Severity | Planned in |
|---|---|---|---|---|---|
| G1 | No single **layer/edition manifest** + orchestrator | 🟡 | tooling | **High** | [02](02-layer-edition-model.md), [05](05-orchestration-observability-roadmap.md) |
| G2 | No **provisioning brain** (turn "tenant wants X" → mounts/policies/keys) | ❌ | control | **High** | [02](02-layer-edition-model.md), [03](03-control-plane.md) |
| G3 | Control-plane daemons stuck in **shadow**, no gated cutover; tenant→ABAC role seeding is a **stub** | 🟡 | control | **High** | [03](03-control-plane.md) |
| G4 | Go/Rust planes **not routed through Kong**; no unified Admin/Control API | 🟡 | gateway | **High** | [03](03-control-plane.md) |
| G5 | **Isolation model** (shared-RLS / schema-per-tenant / db-per-tenant) not selectable per tenant | ❌ | data | **High** | [04](04-data-plane.md) |
| G6 | Capabilities are **descriptive, not enforced**; cost model unused for routing | 🟡 | data | Medium | [04](04-data-plane.md) |
| G7 | **Observability not cross-tier** — Go/Rust expose no `/metrics`, traces don't span TS→Go→Rust | 🟡 | all | Medium | [05](05-orchestration-observability-roadmap.md) |
| G8 | **Credential provider not pluggable** in the data plane (Vault defined but unused as a `CredentialRef` provider) | 🟡 | control/data | Medium | [03](03-control-plane.md), [04](04-data-plane.md) |
| G9 | **SDK doesn't cover the full surface** (functions, webhooks, tenant bootstrap, transactions, admin/migrate) | 🟡 | DX | Medium | [05](05-orchestration-observability-roadmap.md) |
| G10 | **Parity/contract harness** not a first-class, repeatable layer-swap gate | 🟡 | quality | Medium | [05](05-orchestration-observability-roadmap.md) |
| G11 | **No non-Compose packaging** (Helm/K8s) generated from the same manifest | ❌ | deploy | Low | [05](05-orchestration-observability-roadmap.md) |

---

## G1 — No single layer/edition manifest + orchestrator

**Today.** Profiles exist but overlap confusingly: `analytics-service` is in `analytics, background, data-plane`; `minio` is in `storage, data-plane, extras`. There is no declarative statement of *"a Lean BaaS is these planes; a Full BaaS is those; an Analytics edition adds Trino+Iceberg."* `BAAS_LEAN_PROFILES_EXTRA` is referenced in a comment but no composition logic consumes it. The Makefile sets `PROFILES ?=` (a single profile) — you cannot say `make up EDITION=prod`.

**Why it blocks the goal.** "Change layers according to need" is precisely *edition selection*. Without a manifest, every deployment is a hand-rolled `--profile a --profile b` incantation, and there is no validated set of "known-good shapes."

**Target.** One source of truth: `plane → profiles` and `edition → planes`. The Makefile generates `up-<plane>` / `edition-<name>` targets from it (see [05](05-orchestration-observability-roadmap.md) §Makefile). The same manifest later compiles to Helm values (G11).

---

## G2 — No provisioning brain

**Today.** The pieces of provisioning exist but are disconnected: `tenant-control` creates tenants + keys; `adapter-registry` stores DSNs; `permission-engine` holds policies; the Rust router has `/v1/admin/migrate` for per-tenant schema. **Nothing composes them.** A new tenant who wants *"Postgres + Realtime + Storage, schema-per-tenant"* must be wired by hand across three services.

**Evidence.** `tenant-control` `Bootstrap()` (`internal/tenants/service.go`) creates a tenant + key, but `seedDefaultRole()` is an explicit **no-op stub** (lines ~510–523) — the ABAC role is *not* seeded. The comment says so: *"Until that integration lands, bootstrap returns roles=[]."*

**Target.** A control-plane **orchestrator** (Go) that accepts a declarative *tenant stack request* (engines, planes, isolation model, plan/quota) and reconciles it into: tenant row, API key, ABAC roles/policies, mounts in adapter-registry, and (if schema-per-tenant) a `/v1/admin/migrate` call. Idempotent, reconcile-style. Detailed in [03](03-control-plane.md).

---

## G3 — Control-plane cutover is manual; ABAC seeding stubbed

**Today.** `tenant-control` and `webhook-dispatcher` default to `*_PRODUCT_MODE=shadow` with no automated promotion. The slice doctrine (`.claude/instructions.md`) requires shadow → parity → CI-green → cutover, but the promotion itself is a person editing env. The adapter-registry cutover *was* done this way (and the TS service deleted), proving the path — it just isn't repeatable on demand.

**Target.** A `make cutover PLANE=tenant-control` flow that runs the parity gate, checks CI, flips the product mode, and records the decision. ABAC seeding wired into bootstrap (G2). See [03](03-control-plane.md).

---

## G4 — Go/Rust planes are not behind the gateway

**Today.** `adapter-registry-go` (:3021), `tenant-control` (:3022), `webhook-dispatcher` (:3025), and `data-plane-router-rust` (:4011) publish **only on `127.0.0.1`**. They are reachable service-to-service on the docker network, but there is **no Kong route** to the control plane. The README still documents `/admin/v1/databases` — that was the *deleted* TS service. So the public Admin API surface regressed during the Go cutover.

**Target.** Kong routes for a coherent **Control/Admin API**: `/admin/v1/tenants`, `/admin/v1/databases`, `/admin/v1/keys`, `/admin/v1/webhooks`, `/admin/v1/migrate`, guarded by `service_role` key + JWT. One documented admin surface, language-agnostic behind the gateway. See [03](03-control-plane.md).

---

## G5 — Isolation model is not selectable

**Today.** Isolation is hard-coded to **shared-schema + RLS** (Postgres `auth.uid()`) and **owner_id** (Mongo). The Rust `DatabaseMount` already carries `tenant_id` + `project_id`, and `/v1/admin/migrate` can evolve a per-tenant schema — the primitives exist. But there is no abstraction that lets a product choose, per tenant: shared-schema-RLS / schema-per-tenant / database-per-tenant. The docs ship an `Isolation Models` diagram (`docs/images/4._Isolation_Models.png`) describing the intent that code doesn't yet realise.

**Target.** A pluggable **IsolationStrategy** in the data plane + provisioning: the strategy decides schema/search_path/connection selection and how `tenant_id` is injected. See [04](04-data-plane.md).

---

## G6 — Capabilities are descriptive, not enforced

**Today.** `EngineCapabilities` and the `cost { latency_class, pattern_search, joins }` model are defined and surfaced at `/v1/capabilities`, and the SDK is compile-time-typed against them. But at **runtime** the query-router forwards by a static env allow-list (`RUST_DATA_PLANE_FORWARD_ENGINES`), not by negotiating capabilities. A `stream` request to Redis, or a `join`-shaped query to a KV store, isn't rejected/replanned using the cost model — the model is unused for routing.

**Target.** A capability-aware **planner** in front of execution: validate the operation against the mount's capabilities, and use the cost model to choose native vs FDW vs federation (Trino) vs reject-with-clear-error. See [04](04-data-plane.md).

---

## G7 — Observability stops at the TypeScript border

**Today.** TS services expose structured pino logs + `/metrics` (`prom-client`) + `/health/*`, and there's an OTel bootstrap (`libs/common/src/tracing/otel.bootstrap.ts`) plus Tempo/otel-collector configs. But the **Go and Rust services expose no `/metrics`** (only `/health`), and a trace started in query-router does **not** propagate as spans into adapter-registry-go or the Rust router. Prometheus scrapes can't see two of the three planes.

**Target.** `/metrics` on Go (promhttp) and Rust (a metrics layer), W3C `traceparent` propagation TS→Go→Rust, and a "Three Planes" Grafana dashboard. See [05](05-orchestration-observability-roadmap.md).

---

## G8 — Credential provider is not pluggable

**Today.** `DatabaseMount.credential_ref` has `{ provider, reference, version }` — but in practice the DSN is passed **inline** from the TS proxy (`inline_dsn`), and the only real provider is `adapter-registry`. Vault runs (control-plane profile) and `VAULT_ENC_KEY` exists, but there is **no Vault-backed `CredentialRef` resolver** in the Rust `resolver.rs`. Tenant DSN rotation has no path equivalent to `secrets-rotate` for JWT.

**Target.** A `CredentialProvider` trait in the resolver with `adapter-registry` and `vault` implementations selected by `credential_ref.provider`; rotation that bumps `version` and drains old pools by `pool_key`. See [03](03-control-plane.md)/[04](04-data-plane.md).

---

## G9 — SDK doesn't cover the whole product

**Today.** `@mini-baas/js` covers auth / rest / query / storage / analytics / realtime, and ships capability-typed engine clients. Missing from the public surface: **edge functions** (`functions-runtime`), **webhooks** (subscribe/manage), **tenant self-bootstrap** (`/v1/tenants/me/bootstrap`), **transactions** (the Rust router exposes `/v1/transactions*` and engine-clients advertise `.transaction()` for transactional engines — verify it's wired), and **admin/migrate**.

**Target.** Round out the SDK to the full surface so "the SDK is the product API" holds. See [05](05-orchestration-observability-roadmap.md).

---

## G10 — Parity harness isn't a reusable gate

**Today.** `scripts/verify/parity-probe.sh` and `m1..m19` exist and proved the adapter-registry + engine cutovers. But parity is a one-shot script per migration, not a **repeatable, parameterised gate** ("prove plane B matches plane A for route set R, emit a verdict") that any future layer-swap can call.

**Target.** A `make parity OLD=ts NEW=rust ROUTES=…` gate that records a machine-readable verdict, usable for every plane promotion. See [05](05-orchestration-observability-roadmap.md).

---

## G11 — No packaging beyond Compose

**Today.** Everything is Compose. The project's own future-work table (`docs/projet-back.md` §9.4) names *"packaging Kubernetes / Helm / GitOps."* For a product whose value is *layer selection*, the layer manifest (G1) should compile to more than one runtime.

**Target.** Generate Helm values / Kustomize overlays from the same edition manifest. Lower priority — Compose-first is fine until there's a hosting need. See [05](05-orchestration-observability-roadmap.md).

---

## Reading order for the fix

1. **[02](02-layer-edition-model.md)** defines the manifest + edition + capability/isolation model (fixes the *concept* behind G1, G5, G6).
2. **[03](03-control-plane.md)** productionises the Go control plane and adds the provisioning brain + gateway routing + credential providers (G2, G3, G4, G8).
3. **[04](04-data-plane.md)** makes the Rust data plane capability-aware and isolation-pluggable (G5, G6, G8).
4. **[05](05-orchestration-observability-roadmap.md)** delivers the Makefile orchestrator, cross-tier observability, parity harness, SDK completeness, packaging, and the milestone roadmap (G1, G7, G9, G10, G11).
