# 0010 — Mount PATCH rotates through a credential revision, not a DSN hash

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-29, C1–C12), code in G4b.

## Problem

A mount could be registered, described and deleted, but not renamed or re-pointed. The obvious
`UPDATE tenant_databases SET connection_enc = …` route would have been a silent no-op on any busy
mount:

- The Rust data plane keys its pools on `tenant/project/id/engine/credential_ref.version`
  (`mount.rs:83-92`).
- The query-router sent `credentialVersion: 'live'` for every inline mount, at five call sites in
  `query.service.ts` and `schema.service.ts`.
- `release_idle` reaps a pool only after `idle_ttl` without traffic (`registry.rs:216-228`), and
  every request refreshes `last_access`.

So a rotated DSN reached the same pool key, and the old pool kept serving the old host and password
for as long as traffic lasted.

## Decision

- **Migration 094** adds `tenant_databases.revision integer NOT NULL DEFAULT 1`. A `BEFORE UPDATE`
  trigger bumps it when any credential column changes (`connection_*`, `cred_*`, `cmek_*`), and pins
  it to `OLD.revision` otherwise. A caller cannot set it by hand, and a rename or a
  `last_healthy_at` stamp leaves it alone. `schema.go` mirrors the DDL, so a fresh `EnsureSchema`
  install converges with a migrated one.
- **`/connect` returns `revision`.** The query-router sends `credentialVersionFor(revision)`:
  `'live'` for revision 1 (and for anything that is not an integer ≥ 2), `r<n>` otherwise. An
  unrotated mount keeps its exact pool key, so the deploy rebuilds no pool.
- **`PATCH /databases/{id}`** (adapter-registry) takes `{name?, connection_string?,
  credential_ref?}`. It requires the service token and the user, like `connect` and
  `removeScoped`, not like `register`: re-pointing an existing mount is a hijack primitive.
  - The new DSN is sealed outside the transaction, in the row's own mode: inline, or CMEK with the
    row's key id. If CMEK is disabled, the PATCH returns 409 and never downgrades the row.
  - The write is `UPDATE … WHERE id AND tenant_id AND revision = $read`. Zero rows means 409.
  - On success it drops the registry `connCache` entry and logs one line (tenant, id, the revision
    it read, the changed field names; no values).
- **Self-serve `PATCH /v1/tenants/me/mounts/{id}`** follows `deleteMount` (scope `write`) and is
  routed in `MountBuilder` only, never in the read-only `MountMountList`.

## Alternatives considered

- **Pool key from a DSN hash.** Rejected. Shared pools already carry an unkeyed 64-bit
  `stable_hash(dsn)` (`mount.rs:126-137`), and `/v1/admin/rotate` returns pool keys. A second hash of
  the full DSN would be an offline password-guess oracle the moment a key surfaces.
- **Drain via `/v1/admin/rotate` after the PATCH.** Rejected: the query-router's 30 s DSN cache
  re-creates the old pool from the cached DSN within the same window.
- **Gate PATCH like `register` (user only).** Rejected: register creates a mount nobody uses yet,
  while PATCH changes where existing traffic goes.

## Consequences

- A rotation lands in the query-router within its DSN cache TTL (`QUERY_ROUTER_DSN_CACHE_TTL_MS`,
  30 s by default), not instantly.
- The old pool stays open until `idle_ttl` after its last request. The old database password keeps
  working on those sockets until it is reaped or revoked; revoking it is the operator's job.
- In-flight transactions finish on the pool they began on (`transactions.rs:81-104`).
- Mixed deploys: a new registry behind an old query-router behaves exactly as today. The column and
  the PATCH exist, but every request still sends `'live'`, so the rotation stays pending until the
  query-router image is updated. Ship both images together; `m246` fails if any `/connect` consumer
  still sends a literal `'live'`.
- The platform-host 403 applies to the mount's *current* DSN only, and that check is textual
  (`describeDSN`, `descriptor_dsn.go`). The *new* host is not checked, exactly like `register`: there
  is no dial guard until G1's single dial guard lands.
- Static mounts (`DATA_PLANE_MOUNTS`) are not in the registry and cannot be PATCHed.

## Reopen when

- The single dial guard (G1) lands. The new-host check should then go through it.
- The DSN cache gains a cross-service bust, which would make rotation immediate.
- `register` gains a service-token gate. Then the two routes should share one auth helper.
