---
description: Run or inspect Grobase SQL migrations across engines. Usage: /migrate <status|all|mongo|mysql>
---

Action: $ARGUMENTS

Drive the migration lifecycle through the root Makefile (Docker-first). Do NOT hand-edit SQL here — to
AUTHOR a new migration use `/workflow:migrate-db`.

## Workflow

### Phase 1 — Inspect

- `make migrate-status` — applied vs pending.
- Postgres migrations live in `scripts/migrations/postgresql/` (001–090, 79 files; numbering is non-contiguous, e.g. 057–059 are unused).

### Phase 2 — Apply (confirm first — DB writes are irreversible)

- `status` → `make migrate-status`
- `all`    → `make migrate-all`
- `mongo`  → `make migrate-mongo`   (needs the `data-plane` profile up)
- `mysql`  → `make migrate-mysql`   (needs the `data-plane` profile up)
- no arg   → `make migrate`

### Phase 3 — Verify

- Re-run `make migrate-status`; confirm idempotency (re-applying is a no-op).
