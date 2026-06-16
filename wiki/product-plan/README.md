# Product Completion Plan

The plan to take the BaaS from "an excellent chassis with the engine half-built" ([../06-product-assessment.md](../06-product-assessment.md)) to the product in the vision: **engine-agnostic, all operations not just CRUD, OLAP *or* OLTP as a switchable runtime context.**

Read [01](01-overview-and-sequencing.md) first — it sequences the eight workstreams into three shippable phases.

| # | Doc | What it delivers |
|---|---|---|
| 01 | [Overview & sequencing](01-overview-and-sequencing.md) | the master plan, phases, dependencies, definition of "good product" |
| 02 | [Operation contract](02-operation-contract.md) | the one engine-neutral shape for *all* operations (filters, projections, aggregations, joins, cursors, search) |
| 03 | [Engine adapters: full CRUD + rich reads](03-engine-adapters-full-crud-and-rich-reads.md) | implement it — **Postgres update/delete/upsert first** — across every engine |
| 04 | [Honest capabilities + planner](04-honest-capabilities-and-planner.md) | descriptors reflect *implemented* reality; the planner routes by cost |
| 05 | [OLAP/OLTP unified query plane](05-olap-oltp-unified-query-plane.md) | fold Trino in; route by cost; OLAP/OLTP as a switchable context |
| 06 | [SaaS layer](06-saas-multitenancy-quotas-billing.md) | quotas, per-tenant rate limits, usage metering, plan enforcement |
| 07 | [Scale, HA & Helm](07-scale-ha-helm-deployment.md) | horizontal scale, stateful HA, manifest → Helm/K8s |
| 08 | [DX, SDK, GraphQL & tests](08-dx-sdk-graphql-testing.md) | complete SDK, GraphQL, and the e2e matrix gate that stops silent breakage |

## The through-line

`02` defines the shape → `03` implements it → `04` makes the platform *honest* about what's implemented and turns the cost model into a router → `05` uses that router to unify OLAP/OLTP → `06`/`07` make it sellable and scalable → `08` makes it reachable (SDK/GraphQL) and *trustworthy* (e2e gates).

**Phase 1 is the priority: `02 → 03 → 04`.** It makes the brochure match reality — full operations on every engine, honestly advertised. That is the product; everything else builds on it.
