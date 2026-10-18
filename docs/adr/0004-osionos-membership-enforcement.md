# 0004 — osionos membership is enforced in the query that reads, not cached in the bridge

Status: accepted (2026-10-18, devil D3: the bridge membership cache is BLOCKED).

## Context

`osionos_*` tables carry one RLS policy, `service_role_all` (`USING true`), and only
`service_role` holds grants (`pg_policy`, `information_schema.role_table_grants`, 2026-10-18).
The bridge reads as `service_role`, so its `requireWorkspaceAccess` check is the only
authorization — RLS is no backstop. A 293-page open made 587 round trips: one list, then a
membership check and a page read per page (`artifacts/bench/perf-osionos-before.json`).

## Decision

- Batching removes the per-page checks: one membership check per HTTP request, not per page.
- That check runs **in the same statement** that reads the pages (a join or `EXISTS` on
  `osionos_workspace_members` for user + workspace, role where writes are involved): no separate
  check-then-read, so no stale window and no TOCTOU race. The SQL lives in the app's own schema
  file, never in grobase (service-boundaries).
- No membership cache. [Why](../../.out-of-scope/bridge-membership-cache.md)

## Acceptance criteria (on the bridge)

1. Remove a member: the very next request returns 0 rows / 403, with no sleep. Same for a
   non-member, a role downgrade and a deleted workspace.
2. A per-page path calls the check at most once per HTTP request (spy count).
