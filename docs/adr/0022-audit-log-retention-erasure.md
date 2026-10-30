# 0022 — `audit_log` keeps rows for a set period, and an erased user's rows are anonymised

- Status: accepted. On 2026-10-30 the devil ruled PROCEED-WITH-CONDITIONS (C1–C11) on grobase#83. VM rollout pending: it needs its own go and the C11 probes.
- Date: 2026-10-30
- Deciders: devil (ruling). Owners of the orchestrator's gdpr sub-service.

## Context

- `public.audit_log` (013) gets one row per mutating request. It keeps `actor_id`, `ip`, `user_agent`, `payload` and `resource`, and `resource` is `req.originalUrl` (`src/libs/common/src/audit/audit.interceptor.ts:58`), so it includes the query string. All of these can be personal data.
- No rows were ever deleted: there was no retention period. Completing a GDPR deletion request left the user's audit rows as they were.
- The live gdpr path is the Go orchestrator: Kong sends `/gdpr` to `orchestrator:3026`, and the Node `gdpr-service` is in the `legacy-node` profile ("retired", `orchestrators/compose/base/app-services.yml:445`).
- `gdpr.data_deletion_request.user_id` is `TEXT`, while `audit_log.actor_id` is `UUID`.

## Decision

Migration `095_audit_log_retention.sql` adds two functions. The gdpr sub-service (`src/control-plane/internal/orchestrator/gdprsvc/audit.go`) calls them.

- **`audit_log_erase_actor(uuid) → bigint`.**
  - On the user's own rows, it sets `actor_id`, `ip`, `user_agent` and `payload` to NULL, removes the query string from `resource`, and replaces the UUID text with `<erased>`.
  - On other actors' rows whose `resource` contains the UUID, it only replaces the UUID.
  - `request_id`, `action` and `created_at` are kept as the security trail.
  - It returns the number of rows changed; a second call returns 0.
- **`audit_log_purge(interval, int DEFAULT 10000) → bigint`.**
  - It deletes at most `p_batch` rows older than `p_older_than`, lowest `id` first.
  - It raises an error if `p_older_than` is NULL or under 30 days (negative values included), or if `p_batch` is NULL or outside 1..50000. Without the batch guard, `LIMIT NULL` would mean no limit, and 0 would make the caller loop forever.
- **Privileges.** Both functions are `SECURITY INVOKER` with `search_path = public, pg_temp`. On every boot, `REVOKE ALL … FROM PUBLIC, anon, authenticated` runs over every `public.audit_log_%` function, old overloads included. `EXECUTE` is granted to `service_role` only. `service_role` is already `BYPASSRLS` with ALL on the table (`scripts/db/db-bootstrap.psql:35-43`), so `/rpc` gives it nothing it could not already do.
- **Migration shape.** It is a no-op when `to_regclass('public.audit_log')` is NULL. There is no version guard, so the body re-runs on every boot, because `pg-migrate` applies every file at every start without `--single-transaction`. The new index is created with `CREATE INDEX IF NOT EXISTS audit_log_created_idx (created_at)`. **That takes a SHARE lock on `audit_log` while it builds: audit inserts wait.** It only builds once, and the VM table holds 3 rows.
- **Erasure.** `adminProcessDeletion` runs `completed` in this order: the app webhook, then `audit_log_erase_actor`, then the status update. Erasing after the webhook also catches rows the app writes up to its own delete.
  - If the erase fails, the response is a 5xx and the request keeps its status. Both steps are idempotent, so the admin retries.
  - A `user_id` that does not parse as a UUID cannot own an audit row: it is skipped with a log line, and the request completes. A UUID in another spelling (braces, `urn:uuid:`, no dashes) is erased under its canonical form, because Postgres refuses `urn:uuid:` and `resource` carries the canonical text.
  - `in_progress` and `rejected` erase nothing.
- **Retention.** `gdprsvc.Run` purges at boot and then every 24 h until its context is cancelled. It calls the function in batches of 10 000, stops after a short batch, and checks the context between batches.
  - `AUDIT_LOG_RETENTION_DAYS` sets the period: default **365**, `0` disables it.
  - A value of 1–29, a negative number, a value over 36500 or a non-integer disables retention and logs an error. It never stops the orchestrator, which carries five other sub-services.
  - The key is in the orchestrator `environment:` (`orchestrators/compose/base/control-plane.yml`, gate m212) and in `config.env`.
  - **The earliest possible deletion is 2027-05-31**: the table was created on 2026-05-31 (013 header), so a 365-day default deletes nothing before then.
- **Rollback.** Going back to the `legacy-node` gdpr-service loses both erasure and retention: only the Go service calls these functions.

## Residuals (what this does not erase)

- **Rows written with an API key only (`actor_id` NULL).** `erase_actor` cannot tell they belong to the user. They age out through retention only.
- **Personal data in other actors' rows.** An email or a name in another actor's `payload` or query string stays: only the UUID text is replaced. The same goes for a percent-encoded or dash-less copy of the UUID, which the text match does not find.
- **`tenant_audit_log.actor` = `user:<id>`** (`047_tenant_audit_log.sql:58`). That table is hash-chained, so it is left untouched.
- **Loki.** It keeps request logs for 72 h (`infra/config/loki/loki.yaml:38`), and those logs can be joined to an anonymised row through `request_id`.
- **Backups** keep the rows as they were until the backups expire.
- **Sessions.** The user's sessions stay valid after the request completes; this change revokes nothing.
- **"completed" does not mean erased everywhere.** Webhook failures are logged and swallowed (`gdprsvc/webhook.go:94-101`), so a request can complete even though the app never deleted anything.
- **The admin route trusts headers.** `requireAdminUser` checks only `X-Baas-Role == service_role` (`gdprsvc/helpers.go:56-65`), and orchestrator routes have no service-token check. Kong does not route `/gdpr/v1/deletion-requests/admin/{id}/process` (m259 asserts this), but anything already inside the network can call it. That would now also wipe a user's audit trail. Follow-up: [grobase#85](https://github.com/Univers42/grobase/issues/85).

## Rejected

- **Delete the erased user's rows.** That loses the security trail (which request did what, and when). A keyed-hash pseudonym would still be personal data, so it would not count as erasure either. `.out-of-scope/audit-erasure-deletes-rows.md`.
- **The Node gdpr-service as owner.** It is retired and not on the live path. `.out-of-scope/audit-retention-node-gdpr-service.md`.
- **query-router runs the purge (option b).** It splits ownership into a service that has nothing to do with data protection. `.out-of-scope/audit-retention-query-router.md`.
- **A host cron or systemd timer (option c).** It does not come with a fresh clone. `.out-of-scope/audit-retention-host-cron.md`.

## Consequences

- Caveat: the purge runs at boot and every 24 h, so a row can outlive the period by up to a day. An orchestrator that restarts in a loop purges at every start; the batches are bounded and the purge is idempotent.
- Several orchestrator replicas may purge at the same time. They delete the same rows, which is a no-op apart from lock contention.
- Raising the floor or the batch bound means a new migration, because the bounds live in SQL.

## Evidence

- `go test ./internal/orchestrator/gdprsvc/` covers C1–C3, C5 and C6. Each test name states the condition it proves (`audit_test.go`):
  - the order is webhook, erase, update;
  - an erase error gives a 500 and no update;
  - an unset webhook URL still erases;
  - `in_progress` and `rejected` erase nothing;
  - a non-UUID `user_id` is skipped, and a non-canonical spelling is erased as canonical;
  - the knob table: 0, 29, -5, 1.5, 36501 and unset;
  - the purge stops on a short batch and on a cancelled context;
  - `Run` purges at boot when enabled and never when disabled.
- `scripts/verify/m259-audit-retention.sh` uses a throwaway `postgres:16-alpine` with the roles from `db-bootstrap.psql`, then 013, 016, 090, and 095 twice. It checks:
  - every C4 and C5 assertion, run after `SET ROLE service_role`;
  - privileges over every `audit_log_%` function, with a planted overload;
  - that 095 is a no-op on a database without `audit_log`;
  - that the Kong regex does not route the admin path.
- `--self-test` plants four mutants and requires the gate to fail on each: no 30-day floor, no `p_batch` NULL guard, no `REVOKE … FROM PUBLIC`, and no query-string strip. CI runs both modes in the standalone-gates job.
