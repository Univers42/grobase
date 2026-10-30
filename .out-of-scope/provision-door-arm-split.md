# An arm split on `POST /v1/provision` is out of scope

- Decided: 2026-10-30 · by devil (D1 enforce precondition 1, provision-door ruling, ADR 0023)
- Holds while: the door runs only the fixed `CREATE SCHEMA IF NOT EXISTS <sanitized>` statement,
  and any tenant can register its own DSN

## The concept

Under `DATA_PLANE_CALLER_POLICY=enforce`, refuse `INTERNAL_SERVICE_TOKEN` on `/v1/provision` and
accept only the Kong service apikey, as the admin relay does.

## Why not

- The door gives no new reach. Its one statement is fixed (`tenants/dataplane.go:79`, schema
  sanitized at `tenants/provision.go:25-37`). The dial it makes is one any tenant already gets
  through `POST /v1/tenants/me/mounts`, and the `query_router` class may carry an inline DSN with
  any statement (`caller_policy.rs:52-59`).
- The token holder would keep the keys, tenants and erase routes (`tenants/handler.go:77-93`).
  The fix that matters is that the holder stops holding the token: F1 in ADR 0023.
- Under enforce it breaks `cmd/scale-seed/provision.go:92` and `scripts/provision-contract.sh:158`
  unless both get the service key.

## Prior requests

- 2026-10-30 (d1-relay, option P1 of the provision-door plan): rejected by the devil in favour
  of P0 plus F1.

## Reopen when

The door carries a statement the caller can influence, or tenant BYO-DSN goes away.
