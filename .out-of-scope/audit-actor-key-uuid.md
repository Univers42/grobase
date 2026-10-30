# Storing an API key as `audit_log.actor_id`

Declined 2026-10-30 (devil option B, [ADR 0020](../docs/adr/0020-audit-actor-id.md)).

## Why

`actor_id` means one thing: the GoTrue user sub. `audit_log_self_read` matches it against the JWT `sub`. A UUID derived from a key id would put a second id space in the same column. Nothing could tell the two apart, and a collision or a key id that happens to equal a user id would show one actor's rows to another.

## Reopen when

Key attribution is needed. The way to do it is a separate typed `api_key_id UUID` column (ADR 0020, deferred), not a reuse of `actor_id`.
