# A membership cache in the osionos bridge

Declined 2026-10-18 (devil D3, [ADR 0004](../docs/adr/0004-osionos-membership-enforcement.md)).

## Why

The bridge's check is the only authorization on the osionos tables (service_role, `USING true`),
so a cached allow keeps a removed member reading for the TTL — and data read cannot be un-read.
Batching already cuts the checks from one per page to one per request with no cache.

## Prior requests

- 2026-10-18 (devil plan B3): in-flight coalescing of identical BaaS GETs in `baasRest`. A
  request that joins an in-flight read after a revocation commits gets the pre-revocation
  snapshot. That is a cache whose TTL is the statement's in-flight time, up to 8 s
  (`BAAS_FETCH_TIMEOUT_MS`). On paths with no user id in the key it is also shared across
  users. Declined for the same reason.

## Reopen when

- the osionos tables gain an RLS backstop (or the bridge stops reading as service_role), and
- a committed bench shows the uncached per-request check is a material share of `open_ms`
  after batching, and
- for coalescing: a committed baseline shows duplicate in-flight GETs reaching the bridge
  after the client's own in-flight de-dup (osionos `src/shared/api/client.ts`).
