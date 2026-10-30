# 0025. Mongo clients verify the engine cert inside the mongo overlay, with requireTLS as an opt-in mode

- Status: accepted. devil PROCEED-WITH-CONDITIONS, 2026-10-30, M1–M12
- Date: 2026-10-30
- Deciders: devil (ruling); the grobase builder carries M1–M12

## Context

- Mongo serves accept-mode TLS only behind `ENGINE_TLS_ENGINES=mongo` (ADR 0012,
  `infra/docker/services/engine-tls/drop-entrypoint.sh:42-43`). Every client still dials
  plaintext: `auth-api.yml:268`, `app-services.yml:146-147,411,548`, `control-plane.yml:454`,
  `data-plane.yml:226`, healthcheck and mongo-init at `data-engines.yml:259,325-336`.
- Three base DSNs have no `/` before the host's end (`…@mongo:27017`, `auth-api.yml:268`,
  `app-services.yml:411,548`). Measured 2026-10-30, go.mongodb.org/mongo-driver v1.17.7:
  `mongodb://…@mongo:27017?tls=true…` gives `error parsing uri: must have a / before the query ?`.
  The Node driver accepts the same string.
- The Go projector and the realtime producer do not crash when they fail to connect. The Go
  projector logs a warning and turns projections off (`outboxrelay/mongoprojector.go:94-110`). Realtime
  logs "Failed to open change stream" after the 30 s server-selection timeout. It stayed healthy
  at 20 s and was unhealthy at 50 s (measured, grobase-realtime:latest).
- Throwaway probe on 2026-10-30, grobase-mongo:latest under requireTLS with keyfile and rs0, cert from
  `generate-engine-cert.sh mongo`:
  - plaintext mongosh is refused ("connection … closed")
  - verified mongosh, the TLS healthcheck and rs.initiate(host mongo:27017) all work, and the
    node is PRIMARY after 1 s. The image entrypoint's init mongod is plaintext on 127.0.0.1
    whatever the mode.
  - Node, Go and Rust (mongodb 3.7.0, rustls) each connect with `tls=true&tlsCAFile=<path>`.
    Each refuses a host outside the SANs. Go reads a plain or a %2F-encoded path.
  - `mongodump` with no TLS flags exits 1. With `--ssl --sslCAFile /run/engine-tls/ca.pem --host localhost` it exits 0.
- Still plaintext under requireTLS and outside this change: pool mounts with plaintext DSNs
  (`scripts/seed/multidb-workspace-engines.sh:80`, `seed-live-demo.sh:121,158,191,198`), the
  Trino catalog (`infra/docker/services/trino/conf/catalog/mongodb.properties:2`), and any operator
  `OUTBOX_MONGO_URL`.
- Unknown when this was written: whether the real orchestrator boots cheaply in m247 (U1).

## Decision

The mongo overlay owns both ends. When `ENGINE_TLS_ENGINES` lists mongo, the overlay restates
every compose mongo DSN with `tls=true&tlsCAFile=/etc/engine-tls-ca/ca.pem`. It mounts only the
public `ca.pem` file into each client. `ENGINE_TLS_MONGO_MODE` is `allowTLS` by default, or
`requireTLS`. Any other value refuses to start. Taking mongo out of `ENGINE_TLS_ENGINES` reverts the
server and every client together.

## Alternatives considered

- **Clients in their own overlay or knob**: a TLS client could then meet a plaintext server.
  Every service that requires mongo (mongo-api, ai, analytics) would fail to boot.
- **requireTLS as the overlay default**: it breaks the pool mounts, the Trino catalog and the seed
  scripts listed above on the first `make up`.
- **Mount the cert directory**: it holds `engine-key.pem`, which would reach about 7 containers (G5b-C5).
- **Document engine-backup as unsupported under requireTLS**: the measured fix is three flags.

## Consequences

- An expired `engine.pem` (397 days, `generate-engine-cert.sh:101`) is now a client outage even
  in allowTLS. mongo-api, ai and analytics fail to boot. Projections and mongo CDC degrade.
- requireTLS remains a gate mode until the pool gets its own mongo-verification ruling. The pool
  has `DATA_PLANE_TLS_CA_FILE` for mysql and mssql only.
- Conditions M1–M12 are in the devil verdict (groot `.claude/agent-memory/devil/g5-mongo-clients-verdict.md`).

## Found while implementing (2026-10-30, awaits a devil re-rule)

- The `ts-base` anchor (`orchestrators/compose/base/_common.yml:75`) passes `MONGO_URI` through
  from the host env, and `config.env:37` sets it to a plaintext `mongodb://mongo:27017`. With an
  assembled `.env` the render holds 16 mongo DSNs, not 7: email, gdpr, log, newsletter,
  permission-engine, query-router, schema, session and storage-router dial plaintext. compose
  reads this from `.env` even under `--env-file` (measured, compose v2.36.0).
- M2 names seven DSNs, so the overlay does not restate these nine. m247 renders its census with
  `MONGO_URI` empty and lists the nine as a SKIP on every run. They are a requireTLS carve-out
  like the pool mounts, and the overlay's Caveat names them.
