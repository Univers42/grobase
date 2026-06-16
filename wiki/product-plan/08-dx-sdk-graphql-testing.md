# 08 — DX, SDK completeness, GraphQL & the test pyramid

> The product is only as good as what a developer can reach — and as trustworthy as what CI guarantees. The *entire gateway query path was silently 404* until recently; that must never recur.

## Problem

- **SDK is incomplete.** `@mini-baas/js` covers auth/rest/query/storage/analytics/realtime, but **not** functions, webhooks, transactions, tenant self-bootstrap, admin/provision, or the rich-read/OLAP surface from [02](02-operation-contract.md)/[05](05-olap-oltp-unified-query-plane.md). "The SDK is the product API" is the stated goal but not yet true.
- **No GraphQL.** Explicitly absent (`docs/projet-back.md §9.2`). A real differentiator vs Hasura/Supabase; natural fit for the relationship/aggregation contract (02).
- **Thin e2e coverage.** The phase smoke scripts + `mNN` gates check *static code shape* and isolated flows, but no test exercised `engine × operation` **through the gateway** — which is exactly why "Postgres can't delete" and "query route 404s" went unnoticed. The monorepo `tsc` was even red on an orphan.

## Target

1. **SDK covers the whole surface**, fluent and capability-typed, regenerated from honest capabilities ([04](04-honest-capabilities-and-planner.md)).
2. **GraphQL** as an optional plane over the same operation contract + permission engine.
3. **A real test pyramid** with an **e2e matrix gate** in CI that fails the build if any `engine × operation` (or the gateway path) breaks.

## Design

### 1. SDK completeness

Round out `@mini-baas/js` domain by domain, each with type tests:

| Domain | Add |
|---|---|
| query (02) | the fluent builder: `.where(Filter)`, `.select/.agg`, `.orderBy`, `.cursor`, `.join`, `.search`, `.context('olap')` — typed against live caps |
| transactions | `client.tx(async t => { … })` → Rust `/v1/transactions*` |
| functions | `client.functions.deploy()/invoke()` → functions-runtime |
| webhooks | `client.webhooks.subscribe()/list()/delete()` → webhook-dispatcher |
| tenant | `client.tenant.bootstrap()` → `/v1/tenants/me/bootstrap`; admin `provision()` |
| admin | `client.admin.migrate()`, schema introspection |
| usage | `client.usage.get()` ([06](06-saas-multitenancy-quotas-billing.md)) |

- Keep the **codegen discipline**: `sdk/scripts/codegen-engines.mjs` regenerates `generated/engines.ts` from `/v1/capabilities`; `introspectEngines()` fails on drift. Extend drift to features (agg/join/search), not just engine ids.
- The builder's methods are **present in the type** only when the live capability says so → the compile-time guarantee becomes *true* (depends on [04](04-honest-capabilities-and-planner.md)).

### 2. GraphQL (optional plane)

- A `graphql` plane/service that maps the GraphQL schema to the **same** [operation contract](02-operation-contract.md): types ← registered schemas (introspected), queries ← list/get/aggregate/join, mutations ← insert/update/delete/upsert, subscriptions ← realtime.
- Auth + ABAC + quotas reuse the existing guards (it's another front-end over the same plane, like REST/RPC).
- Schema generated from the engine/schema introspection, not hand-written — agnostic by construction.
- Ship behind the `graphql` profile; it consumes 02/03/04, so it lands after them.

### 3. Schema introspection

A `GET /query/v1/:dbId/schema` (and SDK `client.engine(...).schema()`) returning the resource/field/type catalog for a registered DB — powering typed clients, GraphQL types, and an eventual admin UI. PostgREST does this for the internal PG only; generalise it to registered engines via each adapter's introspection.

### 4. The test pyramid (the non-negotiable gate)

```
        e2e matrix (gateway)        ← NEW, CI gate: engine × operation × auth
      integration (per service)     ← extend: each adapter against a real engine
   unit / property (compilers,      ← strong already in Rust core; extend
      planner, cursor codec, ABAC)
```

- **The e2e matrix** (`scripts/e2e/`): for each engine × each operation (CRUD + rich reads + OLAP route), provision a tenant, run it **through Kong with an api-key**, assert results *and* honest 422s. This is the harness that would have caught every gap found in the assessment.
- Wire it into `make test-e2e` and **CI** (`docker-compose.ci.yml`); a red cell blocks merge.
- Add a **contract test**: descriptor ⊆ implemented ops (the [04](04-honest-capabilities-and-planner.md) "no-lying" check) runs in CI.
- Keep the `mNN` milestone gates; add `m20-operations`, `m21-olap-routing`, `m22-quotas`.

## Slices

1. **S1 — e2e matrix harness** (provision → gateway query → assert) for the *current* ops on all engines. *Do this first* — it immediately encodes the truth and catches regressions while 02–05 land.
2. **S2 — SDK query builder** (02 shape) + type tests, regenerated from honest caps.
3. **S3 — SDK domains** (tx, functions, webhooks, tenant, admin, usage).
4. **S4 — Schema introspection** endpoint + SDK.
5. **S5 — GraphQL plane** over the operation contract.
6. **S6 — CI gate** — e2e matrix + contract test block merges.

## Verification

- The e2e matrix is itself the verification: every `engine × operation` cell green (or honest-422), through the gateway, in CI.
- SDK type tests: `.update()` on Postgres is a compile error until [03/A1](03-engine-adapters-full-crud-and-rich-reads.md), then compiles; `.join()` only typed when caps allow.
- GraphQL: a query and a mutation resolve through the same permission/quota path as REST.

## Risks

- **e2e flakiness/cost** — keep it hermetic (ephemeral tenants, cleanup), parallelize per engine; it must be fast enough to gate every PR.
- **SDK/contract drift** — the regen + drift gate is what keeps the SDK honest; never hand-edit `generated/`.
- **GraphQL scope** — it's a *thin* front-end over the contract; resist building a second query engine. If 02 is right, GraphQL is a mapping layer, not a rewrite.
