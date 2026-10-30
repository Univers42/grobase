# Deleting an erased user's `audit_log` rows

Declined 2026-10-30 (devil verdict on grobase#83, [ADR 0022](../docs/adr/0022-audit-log-retention-erasure.md)).

## Why

Deleting the rows also deletes the security trail: which request did what, and when. `audit_log_erase_actor` anonymises the rows instead. It sets `actor_id`, `ip`, `user_agent` and `payload` to NULL, strips the query string, and replaces the user's UUID, while `request_id`, `action` and `created_at` stay. Replacing `actor_id` with a keyed hash was rejected as well: a pseudonym is still personal data, so it would not count as erasure.

## Reopen when

A legal review says the anonymised row is still personal data, for example because `action` together with `created_at` identifies the user in practice.
