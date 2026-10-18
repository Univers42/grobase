# 0005 — the osionos page list and page read take membership from the statement that reads

Status: accepted with conditions (2026-10-18, devil plan B: B1 and B2 PROCEED-WITH-CONDITIONS,
B3 coalescing and B4 delta BLOCKED). Implements [ADR 0004](0004-osionos-membership-enforcement.md)
for two routes.

## Context

- The bridge's check is the only authorization on `osionos_*` (ADR 0004).
- Check-then-read cost two sequential BaaS round trips per request. A reused Funnel connection
  costs 52 ms per round trip, a new one 200 ms or more.
- Pages and members both reference `osionos_workspaces` with `ON DELETE CASCADE`
  (osionos `models/osionos-bridge-migration.sql:40,51`), so a PostgREST embed anchored on the
  caller's `osionos_workspace_members` row compiles to one SELECT: one snapshot, no window
  between the check and the read.

## Decision

- `GET /api/pages/all` and `GET /api/pages` read pages through an embed anchored on the caller's
  members row: `osionos_workspace_members?user_id=eq.U&workspace_id=eq.W&select=…,workspace:
  osionos_workspaces!workspace_id(pages:osionos_pages!workspace_id(…))&limit=2`. That is one
  statement per request, or one per 200-row chunk. Anything other than exactly one row for
  (U, W) is a 403 (`listMemberPageRows`, osionos `scripts/bridge-api.mjs:1271`).
- `readablePageAccess` (`:1069`) reads the page together with the caller's own members row,
  matched by `user_id` (`fetchPageRowWithMember`, `:969`), in one statement.
- Every embed carries an FK hint (`!workspace_id`).
- The JS decision functions are unchanged. The page owner keeps read access after they leave
  the workspace. This is the existing exception to ADR 0004 criterion 1, kept by design
  (`ownerOrWorkspaceAccess`, `:1028`).

## Evidence (2026-10-18, real BaaS through WAF and Kong, read-only)

`perf/membership-e2e-probe.mjs` imports the candidate image's own `bridge-api.mjs` and drives
it in-process. It gave PASS 23/23 (counts and statuses only):

- A non-member with a token that still claims W, and one that never did: 403. The BaaS
  answered 200 with 0 anchor rows.
- The operator gets 1 anchor row and 293 embedded pages, against 293 in the workspace.
- Every filter shape and the 2nd chunk (`id=gt.`) answered 200.
- Page read: the operator's member row is the only one embedded. A non-member gets
  `members: []` and a 403.
- Median upstream time (n = 7): one statement 79 ms, the two calls it replaces 171 ms.

## Acceptance criteria

The devil-B conditions B1-1…B1-10 and B2-1…B2-9. The tests are in osionos
`tests/bridge/bridge-membership-{list,read}.test.mjs`. 12 mutants of the new code were each
caught.

## Not covered (still check-then-read)

Search (`handlePageSearch`, `:2351`), `requirePageScopeAccess` users (`:1142`),
`readablePageGraph` (`:2723`), workspace get/validate, perms engine reads, the comments,
config and backlinks follow-on reads, and every write route (create `:3295`, update `:3364`,
delete `:3798`, cascade, favorites, publish). Writes that need the members row's role need
their own plan.

## Reverse when

The osionos tables get an RLS backstop. The in-statement check then becomes defense in depth
instead of the only gate.

## Alternatives considered

- Membership cache: refused ([why](../../.out-of-scope/bridge-membership-cache.md)).
- In-flight coalescing of identical GETs: a cache whose TTL is the in-flight time, up to
  `BAAS_FETCH_TIMEOUT_MS` = 8 s. Refused, same record.
- An SQL function in the app schema: also one statement, but it needs a prod migration. The
  embed needs none.
- A `since=updated_at` delta: refused
  ([why](../../.out-of-scope/page-list-delta-by-updated-at.md)).
