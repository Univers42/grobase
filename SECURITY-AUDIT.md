# Security Audit & Remediation — Grobase

_Whole-repo vulnerability audit, adversarial verification, and remediation._
_Date: 2026-06-17 · Branch: `chore/sonarcloud-zero-findings`_

This document indexes a full-repository security pass across all three planes (TypeScript
application, Go control plane, Rust data/realtime planes), the SQL migrations, and infra. Every
confirmed issue was **repaired in place** with a Doxygen-style comment block directly above the
repaired unit, each carrying the vulnerability concept, an **official remediation reference**, and
how the fix works. This file is the cross-cutting index; the authoritative per-fix documentation
lives in the code.

## Method

1. **Discover** — a paced multi-agent sweep over tracked code only (dead/untracked trees excluded),
   10 slices across injection, authz/IDOR, SSRF, crypto/randomness, DoS/panic, path traversal,
   headers/CORS/cookies/TLS, and RLS/least-privilege.
2. **Adversarially verify** — every candidate was handed to an independent verifier instructed to
   **refute** it (default verdict = not-real); only findings with a concrete attacker-reachable path
   in tracked code, a cited `file:line`, a CWE id, and a real official reference survived.
3. **Independently re-verify** — each surviving finding was confirmed by hand against the actual
   source before any edit (workflow output is a proposal, not ground truth).
4. **Repair + document** — least-change, engine-agnostic fixes; flag-OFF byte-parity preserved.
5. **Prove** — per-plane build/test gates run green (table at the end).

By-design behaviors were explicitly **not** flagged: SHA-256/HMAC fast-hashing of high-entropy API
keys, flag-gated-OFF cloud/enterprise routes (structurally unmounted = byte-parity), per-request
owner-scoping/RLS (which is what makes `SHARE_POOLS` safe), the front-door ModSecurity WAF, and the
generated-and-gitignored `.env`.

## Confirmed findings & fixes

| # | Severity | CWE | Plane | Location | Status |
|---|----------|-----|-------|----------|--------|
| 1 | High | [CWE-285](https://cwe.mitre.org/data/definitions/285.html) | Rust realtime | `realtime-gateway/.../ws_handler/handlers.rs` · `handle_subscribe_batch` | ✅ Fixed |
| 2 | High | [CWE-89](https://cwe.mitre.org/data/definitions/89.html) | TS app | `schema-service/.../engines/postgres-schema.engine.ts` · `createTable` (+ `schema.dto.ts`) | ✅ Fixed |
| 3 | High | [CWE-269](https://cwe.mitre.org/data/definitions/269.html) | SQL | `scripts/migrations/postgresql/020_fdw_servers.sql` | ✅ Fixed |
| 4 | Medium | [CWE-918](https://cwe.mitre.org/data/definitions/918.html) | TS app | `query-router/.../automations.service.ts` · `postWebhook`/`isPrivateAddress` | ✅ Fixed |
| 5 | Low | [CWE-918](https://cwe.mitre.org/data/definitions/918.html) | Go control | `internal/push/dispatch.go` · `newDispatcher` | ✅ Fixed |

### 1 — Cross-tenant realtime subscription bypass (CWE-285)

`handle_subscribe` gated each subscription on `authorize_subscribe` (the JWT `namespaces`
allow-list), but `handle_subscribe_batch` registered every client-supplied topic with **no**
authorization. An authenticated client scoped to one tenant could `SUBSCRIBE_BATCH` to another
tenant's / `admin` topics and receive all events fanned out there.

**Fix.** Each batched item is now authorized before registration, mirroring `handle_subscribe`
exactly (authorize only when claims are present → NoAuth parity preserved); denied items get an
`AUTHZ_DENIED` frame and are skipped. Purely in the gateway authorization layer → bus/engine-agnostic.
**Ref:** OWASP Authorization / CWE-285.

### 2 — SQL injection in the Postgres schema engine (CWE-89)

DDL was assembled from request-controlled `ColumnDefinition` fields: `col.name` was double-quoted
without escaping and `col.default_value` was concatenated **completely unquoted**, then executed via
node-postgres' simple-query protocol (multi-statement). The sibling MySQL engine already validated
the identical DTO; the Postgres path did not.

**Fix.** `col.name` is validated against an identifier allow-list (`COLUMN_REGEX`) and
`col.default_value` against a strict safe-default allow-list (`SAFE_DEFAULT_REGEX`), mirroring the
MySQL engine (engine-agnostic discipline). Defense-in-depth `@Matches()` added on the DTO boundary.
**Ref:** [OWASP SQL Injection Prevention — Allow-list Input Validation](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html#defense-option-4-allow-list-input-validation).

### 3 — PostgREST-reachable superuser FDW functions (CWE-269)

Migration 020 created `SECURITY DEFINER` functions (owned by `postgres`) that run `CREATE EXTENSION`
/ `CREATE SERVER` DDL. PostgreSQL grants `EXECUTE` to `PUBLIC` by default, and PostgREST publishes
the `public` schema with `PGRST_DB_ANON_ROLE=anon`, so they were callable as `POST /rpc/<fn>` by
`anon`/`authenticated` — privilege escalation to superuser DDL.

**Fix.** Appended a hardening block to 020 (re-applied to existing DBs by the all-files migrate
runner): `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`, `GRANT EXECUTE … TO service_role`, and
`ALTER FUNCTION … SET search_path` on the four privileged functions. **Ref:**
[PostgreSQL — Writing SECURITY DEFINER Functions Safely](https://www.postgresql.org/docs/current/sql-createfunction.html#SQL-CREATEFUNCTION-SECURITY).

### 4 — Webhook SSRF via redirect-follow and IP-literal bypass (CWE-918)

The automation webhook guard inspected only the URL's literal hostname and then `fetch`-ed with the
default `redirect: 'follow'`. A public host could 302-redirect to `169.254.169.254`/internal
services (silently followed), and a hostname resolving to an internal IP — or an IPv4-mapped-IPv6
literal — passed the string-only denylist.

**Fix.** `assertPublicHttpsTarget` enforces https, validates literal IPs (unmapping IPv4-mapped-IPv6,
with the IPv6 branch refusing every non-global-unicast form so both `::ffff:169.254.169.254` and its
hex encoding `::ffff:a9fe:a9fe` are blocked), and DNS-resolves hostnames, rejecting if **any**
resolved address is non-public (fail-closed). The fetch sets `redirect: 'error'`. Residual
within-call DNS-rebind is documented inline (the Go push path pins the connected IP). **Ref:**
[OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html).

### 5 — Push dispatcher DNS-rebinding SSRF (CWE-918)

`guardTarget` validated the host via `net.LookupIP`, but `http.Client.Do` re-resolved independently
at dial time, so a rebinding name could pass the guard then connect to an internal/metadata IP
within a single send. (Flag-gated OFF behind `PUSH_ENABLED` and a service token → low severity.)

**Fix.** The client's dialer now carries a `net.Dialer.Control` hook that re-applies `isBlockedIP` to
the concrete post-resolution address the kernel is about to dial — the validated IP is the connected
IP, closing the rebinding window. The stale comment claiming the send-time re-check defended
rebinding was corrected. **Ref:** OWASP SSRF Prevention Cheat Sheet.

## Verification

All edits were proven against the repo's own Docker-first gates:

| Plane | Gate | Result |
|-------|------|--------|
| Rust realtime | `make rust-realtime-check` (cargo check) | ✅ pass |
| Rust realtime | `make rust-realtime-test` (cargo test) | ✅ pass (`test_subscribe_batch … ok`; integration 28 passed / 0 failed) |
| Go control plane | `make go-control-plane-check` (`go vet` + `go test ./...`) | ✅ pass |
| TS app | `make nestjs-ci` (tsc + eslint + jest, 49 tests) | ✅ pass |
| SQL | hardening block executed on real PostgreSQL 16 | ✅ proven (`anon` EXECUTE = false, `service_role` EXECUTE = true) |

The TS test suite was extended: `automations.service.spec.ts` now proves both IPv4-mapped-IPv6
encodings, private/CGNAT/link-local, and unresolvable-internal targets are rejected while public
IPv4/global-unicast IPv6 are allowed.
