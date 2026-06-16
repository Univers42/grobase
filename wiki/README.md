# mini-baas — plan to a true layer-swappable BaaS product

This wiki is the plan for evolving `mini-baas` from a working BaaS into a **product whose layers you choose** (edition, engine, isolation model, plane mode). Read in order:

| # | Doc | What it answers |
|---|---|---|
| 00 | [Overview](00-overview.md) | What the BaaS is, the 3-language plane pattern, how a request flows, the layer model today |
| 01 | [Gap analysis](01-gap-analysis.md) | The 11 concrete gaps (G1–G11) between "works" and "swappable-layer product", prioritised with evidence |
| 02 | [Layer & edition model](02-layer-edition-model.md) | The manifest: planes → profiles, editions → planes, engine + isolation + product-mode axes |
| 03 | [Control plane (Go)](03-control-plane.md) | Provisioning brain, gateway/admin API, shadow→enabled cutover, credential providers |
| 04 | [Data plane (Rust)](04-data-plane.md) | Capability-aware planner, pluggable isolation strategies, credential seam, transactions |
| 05 | [Orchestration, observability & roadmap](05-orchestration-observability-roadmap.md) | The Makefile orchestrator, cross-tier o11y, parity gate, SDK, packaging, P0–P7 roadmap |
| 06 | [Product assessment](06-product-assessment.md) | Honest evaluation: is it a *good product* yet? (verdict: strong chassis, engine half-built) |

## ➡️ The product completion plan ([product-plan/](product-plan/README.md))

Docs 00–05 made the platform **layer-swappable**; doc 06 measured it against the **product** bar and found the core value (operations + OLAP/OLTP intelligence) incomplete. The **8-document [product-plan/](product-plan/README.md)** is the roadmap to close that — finish *all* operations on every engine, make capabilities honest, unify OLAP/OLTP as a switchable runtime context, add the SaaS layer (quotas/metering/plans), scale (Helm/HA), and complete the SDK/GraphQL + e2e gates. **Start with Phase 1: [02 operation contract](product-plan/02-operation-contract.md) → [03 full CRUD](product-plan/03-engine-adapters-full-crud-and-rich-reads.md) → [04 honest capabilities](product-plan/04-honest-capabilities-and-planner.md).**

## 🚀 Go-to-market (competitive parity & launch)

The market-facing track: how Grobase stacks up against the BaaS leaders and the
plan to ship it as an OSS-first product. Authored from a deep audit + benchmark
(2026-06).

| Doc | What it answers |
|---|---|
| [Competitive matrix](competitive-matrix.md) | Feature-parity vs **Supabase + Firebase** (~91 rows) + the differentiators neither has |
| [Grobase vs Supabase — offer](grobase-vs-supabase-offer.md) | Service-for-service map with **measured** footprint/latency (lighter + faster, like-for-like) |
| [Marketability readiness](marketability-readiness.md) | The four launch bars (parity / scale-SLO / security / live-signup) as checkable gates |
| [Roadmap to market](roadmap-to-market.md) | OSS-first phased plan (Track A → OSS launch; Tracks B+C → managed cloud) |
| [Security audit (ASVS)](security-audit-asvs.md) | OWASP ASVS L1/L2 + SOC2-lite control map + open residuals |
| [Migrate from Supabase](migrate-from-supabase.md) | Dependency-swap guide — the SDK is Supabase-shaped |
| [Migrate from Firebase](migrate-from-firebase.md) | Cross-paradigm translation (Firestore/RTDB/Rules → engines + RLS) |

## The one-paragraph thesis

The platform already separates concerns across **three language planes** — TypeScript (application/business), Go (control: tenancy, secrets, webhooks), Rust (data: engine pools) — and already expresses "layers" as **compose profiles** plus runtime **product modes**. It is *not yet* a product you can reshape on demand because it lacks: a single **layer/edition manifest + orchestrator** (now delivered as `mini-baas-infra/Makefile`), a **provisioning brain** to turn intent into mounts/policies/keys, **gateway routing** for the Go/Rust planes, a selectable **isolation model**, **capability-aware routing**, **cross-tier observability**, and a repeatable **parity gate** for safe layer swaps. Docs 02–05 plan each of these as independently shippable, reversible slices — consistent with the project's existing shadow→parity→cutover discipline.

## Operating the stack

All Docker lifecycle goes through the Makefile orchestrator (never raw `docker compose`):

```bash
make help          # all targets
make planes        # planes → profiles
make editions      # editions → planes
make up EDITION=query     # start a known-good shape
make up-analytics         # add a plane live; make down-analytics removes it
make doctor               # environment sanity check
```
