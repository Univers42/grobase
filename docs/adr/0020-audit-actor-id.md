# 0020 — `audit_log.actor_id` is a GoTrue user sub or NULL

- Status: accepted. On 2026-10-30 the devil ruled PROCEED-WITH-CONDITIONS (A1–A10) on option A. The code is on develop; the VM probes P1–P6 have not been run yet.
- Date: 2026-10-30
- Deciders: devil (ruling). Owners of `audit_log_self_read` and of anything that reads `actor_id`.

## Context

- `public.audit_log.actor_id` is a `UUID` (`scripts/migrations/postgresql/013_audit_log.sql`). `audit_log_self_read` compares it to the JWT `sub`.
- `ApiKeyMiddleware.resolveOwner` sets the user id to one of two forms, and under kong-hmac it reaches the query-router as `x-baas-user-id`:
  - `api-key:<keyId>` when only an app key is sent;
  - `user:<sub>` when a verified user JWT is sent with the key.
- The interceptor stored `req.user.id`. `identityToUserContext` (`request-identity.ts:78`) falls back to the tenant id when the user id is absent.
- On the b2b VM (ADR 0018's swap, 2026-10-30 10:02:54Z), every bridge POST failed its insert with `invalid input syntax for type uuid: "api-key:…"`. `audit_log` held 0 rows.

## Decision

`auditActor(req.identity)` (`src/libs/common/src/audit/actor.ts`) is the only place the actor is built. It takes the verified identity, not `req.user`.

| authMethod | `actor_id` | `actor_role` |
| --- | --- | --- |
| `kong-hmac`, `user:<uuid>` | `<uuid>` | identity role |
| `kong-hmac`, any other value (`api-key:…`, bare uuid, `User:…`) | NULL | identity role |
| `jwt` | sub if it is a UUID, else NULL | identity role |
| `legacy-header` | bare UUID only; the `user:` prefix is never stripped (unsigned) | identity role |
| `service-token` | NULL | `service_role` |
| `mtls`, no identity | NULL | NULL |

- `actor_id` never holds an API key, tenant or service id. `actor_role` is never `api_key`.
- The payload is redacted recursively before it is stored. Secret-named keys at any depth become `[REDACTED]`. Past depth 4, and past 256 entries per object or array, the value is replaced with `[TRUNCATED]` rather than stored unscanned.
- No schema change. The outbox is untouched.

## Rejected

- **B: derive a UUID from the key id.** It mixes two id spaces in one column, and `audit_log_self_read` could match a key-derived id against a user sub. `.out-of-scope/audit-actor-key-uuid.md`.
- **C: an `actor_text` column.** It needs a schema change on a live table that has RLS and a REST read grant.
- **Map the outbox actor the same way.** Outbox topics have no tenant segment, so user ids would be broadcast, and `outbox.rs:114` expects NULL. That needs its own ruling.
- **Put the mapping in `request-id.ts`.** That file is the request id, not the actor.

## Deferred

- A typed `api_key_id UUID` column, so key-only requests can be attributed.

## Consequences

- Key-only requests are stored with a NULL actor, so they cannot be attributed to a key until the deferred column exists.
- Caveat: redaction matches key names only (`password`, `secret`, `token`, `apikey`, `api_key`, substring, case-insensitive). A secret stored under any other name, or inside a string value, is stored as sent.
- Open tickets:
  - F1 (grobase#82): `verifyUserJwt` in `ApiKeyMiddleware.resolveOwner` has no issuer pin (`api-key.middleware.ts:183`).
  - F2 (grobase#83): there is no GDPR or retention deletion of `audit_log` rows.

## Evidence

- jest in node:22: 43 suites, 709 tests passed. prettier, eslint `--max-warnings 0`, and tsc (lib, query-router, root) are clean.
- `actor.spec.ts` covers:
  - the mapping table;
  - that the tenant id is never used;
  - that `$2` is bound as a UUID or NULL for every authMethod × user id;
  - nested redaction, depth truncation and the entry cap.
- Mutations caught:
  - `legacy-header` handled like `kong-hmac` → 2 tests failed.
  - Top-level-only redaction → 1 test failed.
- VM probes (A8, not run yet), user-agent `devil-probe-2026-10-30`:
  - P1: key only → NULL actor.
  - P2: key + user JWT → actor = sub.
  - P3: self-read shows P2 and not P1.
  - P4: anon is refused.
  - P5: no uuid insert errors.
  - P6: a nested password is stored redacted.
