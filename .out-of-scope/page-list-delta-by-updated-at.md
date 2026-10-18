# A page-list delta keyed on osionos_pages.updated_at

Declined 2026-10-18 (devil plan B4, [ADR 0005](../docs/adr/0005-osionos-membership-in-statement.md)).

## The idea

Re-pull `/api/pages/all?since=<max updated_at seen>` and read only `updated_at >= since`.

## Why not

- A page PATCH stamps the client's clock. The bridge accepts any past time and refuses only a
  time more than 5 min in the future (osionos `scripts/bridge-api.mjs`, the PATCH stamp guard).
  Other writers stamp server time. A client whose clock runs fast hides other clients' writes
  from every delta. A slow clock, or a deliberate 1970 stamp, means the write is never seen. The
  miss lasts until a full reload, and a stale full-content PATCH can then overwrite the write.
- Deletes and workspace moves never appear in a delta.

## Reopen when

- A server-assigned change marker exists that no client can write (set by a trigger), and
- deltas are read with an overlap margin at least as long as the longest write transaction, or
  with a txid watermark, and
- deletes and moves leave tombstones.
