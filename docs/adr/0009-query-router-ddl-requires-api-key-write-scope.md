# 0009 — Query-router schema DDL requires a write-scoped app key

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-29, C1–C14), code in G1g.

## Problem

`POST /query/v1/:dbId/schema/ddl` (`SchemaService.applyDdl`) checked only `confirm: true` on
destructive ops. Any identity that reached the route could change that tenant's schema, including a
**read-only app key** sending `drop_table` with `confirm: true`.

- The data plane's envelope route `/v1/schema/ddl` trusts the query-router to decide.
- The sibling bypass route `/data/v1/schema/ddl` already requires `write` (`bypass.rs:146`).
- The PDP cannot rule on DDL: `DECISION_OPS` has no `ddl` action (`decision.dto.ts:5`).

## Decision

`applyDdl` admits exactly one caller: a **kong-hmac** identity that is an app key (`api-key:<id>`), or a
user riding one (`user:<sub>` with appId `api-key`), holding `write` or `admin`. Everyone else gets a
403:
- `jwt`
- `legacy-header`
- `service-token`
- `mtls`
- no identity
- an unknown method

The check runs first, before the `confirm` check, before `describe` (which `alter_column_type` calls)
and before `resolveConnection`. So a refused caller costs no database round-trip and cannot tell
whether a table exists.

The app-key detection (`apiKeyScopes`) and the scope rule (`hasApiKeyScope`, where `admin` satisfies
everything and matching is exact) live in `query/api-key-scope.ts`. `decideByApiKeyScope` uses the
same function, so the two cannot drift apart.

A refusal logs one JSON line:
- it contains `{event, dbId, tenantId, userId, authMethod, op, reason}`;
- control characters are stripped from every field;
- it never carries the DDL body, column defaults or a DSN.

The new rule is enforced by default, with no flag. Every measured caller holds `write`:
- the osionos bridge;
- the seed scripts;
- the verify scripts;
- the postman corpus.

A wrong deny shows up as a loud 403, and the image rollback undoes it.

## Alternatives considered

- **Allow JWT and legacy-header users on their own tenant (`tenantId === userId`).** Rejected because it
  protects nothing:
  - Behind Kong, `X-Baas-Tenant-Id` / `X-Tenant-Id` are cleared, so the legacy identity falls back to
    `tenantId = userId` and the test always passes.
  - A forger on the docker network sets both headers.
  - No JWT DDL caller exists.
- **Allow `service-token`.** Rejected because no request can reach it: `SchemaController` uses
  `AuthGuard`, and `resolveRequestIdentity` never produces `service-token`. A branch for it would be a
  test that proves nothing.
- **A flag (off / enforce).** Rejected because nobody would ever turn it on. The sibling route already
  enforces the rule.
- **`decideByApiKeyScope(identity, 'ddl')`.** Rejected because `ddl` is in neither of its op sets, so
  it would demand `admin` and refuse write keys.

## Consequences

- A read-only app key can no longer change a schema. A JWT user cannot either, until the PDP has a `ddl`
  action ([out of scope](../../.out-of-scope/jwt-user-schema-ddl.md)).
- **Static mounts.** `DATA_PLANE_MOUNTS` mounts are still matched by `dbId` alone, so any tenant's write
  key reaches them. The live count is 0, measured 2026-10-29. Tracked in
  [#78](https://github.com/Univers42/grobase/issues/78).

## Reopen when

- A measured JWT or legacy-header DDL caller exists, and the G1a signed-envelope enforcement is live.
- The PDP gains a `ddl` action. Shared-tenant members could then be ruled per role.
