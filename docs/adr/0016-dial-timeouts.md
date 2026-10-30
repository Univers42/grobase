# 0016 — A dead mongo or mssql fails a request in 5 s, not 30 s (m230)

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, D1–D7). Code on develop; D6 measured (below); VM rollout is D7.

## Problem

A dead engine held every request for 30 s before failing. There were two separate causes.

- **mongo.** `mongo/adapter.rs` set `server_selection_timeout = max(idle_ttl_ms, 5 s)`.
  `idle_ttl_ms` is the pool-eviction TTL, 30 000 by default (`data-plane-core/src/mount.rs`).
  The line also overwrote any `serverSelectionTimeoutMS` the DSN had set.
- **mssql.** The bb8 builder set no `connection_timeout`, so bb8's 30 s default applied to
  both the dial to a dead server and a checkout from a saturated pool.

The data-plane server has no request-level timeout: the only `tokio::time::timeout` in it is
`routes/probe.rs`. That makes the engine timeout the whole bound on how long a request is held.

## Decision

- **mongo:** the DSN's `serverSelectionTimeoutMS` is honoured, clamped to 30 s. With none in
  the DSN, the default is 5 s (`server_selection_timeout`, `SELECTION_DEFAULT`,
  `SELECTION_CAP`). `idle_ttl_ms` no longer appears in the adapter.
- **mssql:** `connection_timeout` is 5 s (`CHECKOUT_TIMEOUT`).
- **Tests:**
  - `canary.rs` `DIAL_BOUND` drops from 45 s to 10 s.
  - `a_dead_mongo_or_mssql_fails_within_six_seconds` dials each engine twice, with a DSN that
    sets no timeout: once at a refused port, and once at a listener that completes the
    handshake and then never answers.
  - Mutation-checked. Restoring bb8's 30 s makes the test fail on `mssql list hung`; a 9 s
    mongo default fails it on `took 9.0s`.
  - `selection_timeout_defaults_honours_and_caps_the_dsn` covers a missing value (5 s),
    `500` (500 ms) and `600000` (30 s).

## Consequences

- **D1 — not cleared by the code alone.** During a replica-set election (about 10–12 s with
  the default `electionTimeoutMillis`), requests now fail instead of waiting it out.
  Mitigation: such a mount sets `serverSelectionTimeoutMS` of about 15 s in its DSN before
  the rollout (D6).
- **mssql checkout.** A burst above `pool_policy.max` now fails after 5 s instead of queueing
  for 30 s. Mitigation: raise `max` for that mount.
- **Tenant timeouts are capped.** A tenant can no longer set a timeout longer than 30 s. One
  that sets less gets what it asked for.
- **D6 — rollout gate.** Before the VM image changes, count the VM's mongo mounts that use
  `replicaSet=` or `mongodb+srv` and its mssql mounts, and report both numbers.
  Measured 2026-10-30 on b2b, read-only (`public.tenant_databases` by engine, `rs.conf()`):
  - 5 mongodb mounts and 2 mssql mounts, served by one mssql server container.
  - `mini-baas-mongo` is `rs0` with one voting member (`electionTimeoutMillis` 10000). A
    one-member set has no failover election, so the D1 wait does not arise there.
  - `drill-mongo` runs without replication.
  - Not measured: which of the 5 DSNs carry `replicaSet=` or `mongodb+srv`. The DSNs are
    AES-256-GCM encrypted and were not decrypted. A mount pointing at a multi-member set
    elsewhere would still hit D1.
- **D7 — rollout.** The rollout is a separate step under a `:pre-` tag. After the swap, run
  one probe per live mongo and mssql mount.

## Rejected

- **Keeping `max(idle_ttl_ms, …)`.** It couples eviction to the dial, and it silently
  discards the tenant's DSN value.
- **Honouring the DSN value uncapped.** With no request timeout above the adapter, a DSN
  with `serverSelectionTimeoutMS=600000` would hold router tasks for 10 minutes.
