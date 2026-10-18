# A membership cache in the osionos bridge

Declined 2026-10-18 (devil D3, [ADR 0004](../docs/adr/0004-osionos-membership-enforcement.md)).

## Why

The bridge's check is the only authorization on the osionos tables (service_role, `USING true`),
so a cached allow keeps a removed member reading for the TTL — and data read cannot be un-read.
Batching already cuts the checks from one per page to one per request with no cache.

## Reopen when

- the osionos tables gain an RLS backstop (or the bridge stops reading as service_role), and
- a committed bench shows the uncached per-request check is a material share of `open_ms`
  after batching.
