# 0017 — Under SECURITY_MODE=max, Postgres upgrades opportunistic TLS to verify-full with TLS enforced on the wire, refuses `disable`/`allow`, and Dynamo refuses a non-https endpoint

- Status: accepted. devil ruled PROCEED-WITH-CONDITIONS on 2026-10-30, conditions T1–T12. Code on develop; T4 measured (Evidence). No deployment runs max yet (T9).
- Date: 2026-10-30
- Deciders: devil (ruling). The data-plane owner and whoever flips a deployment to `max` live with the outcome.

## Context

- Plan item: `wiki/architecture/multidb-holistic.md:336`. MySQL/MariaDB are already covered (`mysql/tls.rs`, G5b-C10). MSSQL ignores `DATA_PLANE_TLS_INSECURE` under max (`mssql/adapter.rs:126-131`).
- Today, with max on and no `sslmode` in the DSN, Postgres gets `None`, which means the NoTls connector (`postgres/conn.rs:38-50`). A test pins that behaviour (`conn.rs:362-365`).
- tokio-postgres 0.7.18 defaults to `SslMode::Prefer` (`tokio-postgres/src/config.rs:255`). With Prefer, a server that answers `N` to SSLRequest gets a **plaintext** stream back (`connect_tls.rs:41-46`). With `Disable`, tokio-postgres returns Raw before it looks at the connector (`connect_tls.rs:22`). So handing a rustls connector to a DSN still set to prefer/missing/disable does not guarantee TLS, even though `tls_posture` would report `Verified`.
- tokio-postgres accepts only `disable|prefer|require` (`config.rs:584-590`). A DSN with `sslmode=allow` fails to parse in every mode today.
- deadpool-postgres 0.14.1 applies `Config.ssl_mode` after it parses the URL (`deadpool-postgres/src/config.rs:198-199, 278-280`). One field therefore forces `Require` whatever the DSN says.
- CockroachDB mounts go through the same `PostgresAdapter::open_pool` (`postgres/adapter.rs:38,77`). The compose CRDB runs `--insecure` (`orchestrators/compose/base/engines-extra.yml:141`).
- Dynamo with no DSN `endpoint=` reports `Verified` (`dynamodb.rs:858-861`). But aws-config 1.8.13 resolves `AWS_ENDPOINT_URL` and the profile `endpoint_url` when no endpoint was set in code (`aws-config/src/lib.rs:912-933`). aws-sdk-dynamodb 1.104.0 also resolves `AWS_ENDPOINT_URL_DYNAMODB` (`aws-sdk-dynamodb/src/config.rs:1453-1455`).
- The seeded Dynamo endpoint is `http://dynamodb-local:8000` (`scripts/seed/multidb-workspace.sh:58`).
- Helm prod sets `SECURITY_MODE: "max"` (`deploy/helm/grobase/values.yaml:39`). No compose file or CI job sets it.
- Platform-internal pools stay NoTls in every mode (`data-plane-server/src/outbox.rs:144`, `automations.rs:166`).
- VM data plane measured 2026-10-30: `SECURITY_MODE=baseline`, `DATA_PLANE_TLS_INSECURE=1`. Mounts: postgresql 9, cockroachdb 1, dynamodb 2.
- Unknown when this was written: the sslmode and endpoint scheme of every VM mount (the DSNs are AES-GCM encrypted and were not decrypted). Whether any helm install exists.

## Decision

Under `SECURITY_MODE=max` only:

- **Postgres/CockroachDB.** A missing `sslmode`, or `prefer`, maps to `TlsMode::Verify`, and the pool config forces `ssl_mode = Require`, so the handshake is mandatory on the wire. `disable` and `allow` are refused at `open_pool`, before any pool exists. `require` and `verify-*` keep their current behaviour.
- **Dynamo.** The DSN's `endpoint=` (or real AWS when it has none) is pinned on the service builder (`dynamodb_endpoint::pinned_builder`), so `AWS_ENDPOINT_URL*` and the profile can no longer redirect the dial and the posture label is exact. A non-`https://` endpoint is refused before `loader.load()`; the message carries no DSN.
- Baseline behaviour does not change at all.

## Alternatives considered

- **Upgrade everything, `disable` included.** Lost because it overrides an explicit operator statement. It is also unsafe unless the wire is forced: `Disable` returns Raw (`connect_tls.rs:22`), which would be plaintext labelled `Verified`. Against a non-TLS server it still fails, with a TLS error that does not name the cause.
- **Refuse every non-TLS DSN, including missing/prefer.** Lost because it breaks a mount whose server already has a valid certificate but whose DSN omits `sslmode`. Hosted Postgres connection strings commonly do that. The plan item asks for an upgrade there.
- **Upgrade `allow` by rewriting the DSN.** Lost because no working `allow` mount exists: tokio-postgres rejects the value (`config.rs:589`). Writing rewrite code for zero callers is YAGNI.
- **Change only the connector (the plan as written).** Lost because tokio-postgres's `Prefer` default falls back to plaintext. An on-path attacker answering `N` strips TLS while the probe reports `Verified`.

## Consequences

- When a deployment is flipped to max (any helm install, or the VM if it is ever switched), these mounts stop serving at their first pool open: every Dynamo mount on `http://` (both VM mounts, if they come from the seed), the `--insecure` CRDB, and every Postgres mount whose server does not serve a cert that chains to webpki roots or `DATA_PLANE_TLS_CA_FILE`. That is the intended meaning of max. It has to be inventoried first (T9).
- Max still does not cover the outbox or automations pools. That gap stays open and needs its own ruling.
- Reversal is a code revert, or setting `SECURITY_MODE=baseline` and restarting the data plane.

## Evidence

- Gate (`cargo fmt --check`, `clippy -D warnings`, `cargo test -p data-plane-pool --lib`): 431 passed default, 468 passed `--features dynamodb`, clippy clean both ways.
- Mutation: dropping `set_endpoint_url` fails `pinned_builder_dials_the_dsn_endpoint_not_the_shared_one`; dropping the `ssl_mode` pin fails `tls_modes_pin_the_handshake`.
- T4 live, 2026-10-30: throwaway `postgres:16-alpine` boots on a scratch network, one `ssl=off`, one `ssl=on` with a cert from a throwaway CA passed as `DATA_PLANE_TLS_CA_FILE`; the pool is opened through `PostgresEngineAdapter::open_pool` and probed.

| SECURITY_MODE | server | DSN sslmode | result |
| --- | --- | --- | --- |
| max | ssl=off | none | refused at first checkout (`probe: pool checkout failed`) |
| max | ssl=off | disable | refused at `open_pool`: `SECURITY_MODE=max refuses a Postgres mount with sslmode=disable` |
| max | ssl=on | none | `Verified`, TLSv1.3 |
| max | ssl=on | prefer | `Verified`, TLSv1.3 |
| baseline | ssl=off | none | `Plaintext` (unchanged) |
| baseline | ssl=on | verify-full | `Verified`, TLSv1.3 (unchanged) |

- Caveat: the first row shows the probe's fixed text (P7 keeps host and user out of errors), not tokio-postgres's "server does not support TLS". The baseline row against the same server and credentials connects, so the refusal is the forced handshake.
