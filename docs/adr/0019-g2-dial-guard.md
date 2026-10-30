# 0019 — Every tenant DB dial goes through one guard that resolves, classifies and pins the IP at dial time

- Status: proposed; D1 (pgwire, MySQL) and D3a (Redis) delivered, flag off. On 2026-10-30 the devil ruled D1, D2, D3a (Redis) and D4 PROCEED-WITH-CONDITIONS (C1–C14), D3b (Mongo, as planned) BLOCK, and enforce on the VM with a subnet-wide allowlist BLOCK.
- D1 delivered 2026-10-30, flag default `off`: one classifier, the mode flag, provenance, and pgwire and MySQL pinning (section D1). The Rust gate and `m244` are green. D2–D4 and any VM flip are not started.
- Date: 2026-10-30
- Deciders: devil (ruling). Owners of data-plane-pool and of every live mount on the VM.

## Context

- Only the http engine is guarded (`data-plane-pool/src/http/validate.rs:86-187`). Every other engine dials the DSN host itself.
- Every DSN comes through `resolver.rs:193`. Live traffic arrives as `inline_dsn` from the query-router (`resolver.rs:194-203`), so every live mount is Tenant provenance, platform-seeded ones included.
- The pooler repoint keeps the tenant's `?query` (`postgres/conn.rs:119-151`). tokio-postgres 0.7.18 takes `host=` and `hostaddr=` from the query (`config.rs:605-614`), so a repointed DSN can still dial a tenant-chosen IP.
- deadpool-postgres 0.14.1 appends `hostaddr` to the URL-parsed config (`config.rs:252-257`). A count mismatch with `host` errors (`tokio-postgres connect.rs:27-33`).
- redis 0.27.6 is built without TLS (workspace `Cargo.toml:98`), so `rediss://` fails at parse (`connection.rs:378-382`).
- mongodb 3.7.0 starts the monitor (`sdam/topology.rs:593`) before it emits `ServerOpening` (`:606`). The handler cannot veto, so every discovered host gets a connect and a handshake. The `socks5-proxy` feature (`Cargo.toml:136`) passes the host *name* to the proxy (`runtime/stream.rs:81`).
- bb8-tiberius 0.15.0 re-dials a server-chosen Routing host without any check (`lib.rs:111-122`).
- The AWS SDK resolves DNS itself. aws-smithy-http-client 1.1.13 provides `build_with_resolver` (`client.rs:792`).
- The seeded DynamoDB DSNs carry static keys (`scripts/seed/multidb-workspace-engines.sh:125`, `osionos-extra-engines.sh:424`).
- Unknown when this was written: the live mounts' hosts (shadow measures them), and whether any tenant uses PG multi-host or a MySQL socket.

## Decision

- `dial_guard` is the only classifier. It runs on the driver-parsed config at each physical dial. It denies loopback, link-local, unspecified, multicast and reserved addresses for Tenant DSNs, and private addresses unless an allowlist entry admits them. It pins the vetted IP.
- Provenance is a resolver return value. It is Platform only for the static `DATA_PLANE_MOUNTS` step.
- `DATA_PLANE_DIAL_GUARD=off|shadow|enforce`, default `off`. A value outside that set fails startup.

## Alternatives considered

- **Classify once per pool open.** A docker recreate leaves the pinned pool dialing a stale IP, and docker can hand that IP to another container.
- **Mongo SDAM event handler.** It is reactive by construction (topology.rs:593 runs before :606).
- **Mongo `directConnection=true` everywhere.** This breaks failover for tenant replica sets.
- **Global RFC1918 or docker-subnet allowlist under enforce.** It admits every platform service on that subnet to every tenant (see `.out-of-scope/dial-guard-subnet-allowlist.md`).
- **Hostname-only check for DynamoDB and Redis.** It leaves a DNS-rebinding window, and both drivers can be pinned.

## Consequences

- The builder must meet conditions C1–C14 from the 2026-10-30 ruling. They are recorded in devil memory `g2-dial-guard-verdict`.
- The always-on http classifier changes (224/4, 240/4, 198.18/15, embedded-IPv4 decoding) apply even when the guard is off.
- Mongo stays unguarded until the SOCKS5 lift lands.
- Enforce on the VM waits for G1 enforce and an exact `ip:port` or per-tenant allowlist.

## D1 — what the slice delivers (pgwire, MySQL, the shared classifier)

Code lives in `data-plane-pool/src/dial_guard/` (`classify.rs`, `scope.rs`), `postgres/dial.rs` and `mysql/dial.rs`. The static gate is `scripts/verify/m244-dial-guard.sh`.

- **One classifier.** `http/validate.rs` calls `dial_guard::classify` and `denied_name`. Its own `is_blocked_ip` is deleted.
- **The flag.** The server reads `DATA_PLANE_DIAL_GUARD` once (`ServerConfig::dial_guard`) and hands it to the postgresql, cockroachdb, mysql and mariadb adapters. A value outside `off|shadow|enforce` stops startup with `ConfigError::UnknownDialGuardMode`. `off` takes the pre-G2 code path: no lookup, no pin, no log line.
- **Provenance.** `MountResolver::resolve` returns `ResolvedDsn { dsn, provenance }`. Only the static `DATA_PLANE_MOUNTS` step returns `Platform`. Inline DSNs, the replica inline DSN (`read_replica_variant` moves it into `inline_dsn`) and the credential providers return `Tenant`. The value is never read from the mount or the request body.
- **The pooler repoint is not Platform.** Only the exact `host:port` of `DATA_PLANE_POOLER_URL` skips classification, and it is still pinned to its resolved IP. A tenant `host=` or `hostaddr=` that survives the repoint in the query is classified like any other.
- **pgwire.** The guard reads the driver-parsed `tokio_postgres::Config`. Every TCP host is resolved and classified, and so is every tenant `hostaddr`. The vetted config is a new `Config` with one vetted `hostaddr` per host; it replaces the tenant's list rather than extending it. A unix-socket host is refused. Under enforce the open fails before a pool exists. A custom deadpool `Connect` (`Manager::from_connect`) resolves and classifies again at each physical dial, so a recreated container's new IP is picked up on the next connection.
- **MySQL.** The guard reads the driver-parsed `Opts` and refuses `socket=`. It resolves and classifies `ip_or_hostname()`, and under enforce builds the pool with `resolved_ips(vetted)` and `prefer_socket(false)`. mysql_async has no per-connection hook, so the guard re-vets at checkout every 30 s and swaps the pool when the vetted set changes.
- **Shadow.** It logs `dial_guard would_deny` and then dials exactly as `off` would. The line carries engine, mount_id, tenant_id, provenance, class, ip, port and the host, Debug-escaped and capped at 253 bytes. It never carries the userinfo, the password, the database or the DSN query (m230 canary `a_dial_guard_refusal_never_repeats_the_password`).
- **Enforce** logs `dial_guard deny` with the same fields, then refuses: `<engine> dial refused by the dial guard: destination class <class>`.
- **No subnet allowlist.** Tenant private addresses (RFC1918, ULA, CGNAT) are denied with no exception. Per C13 and YAGNI no allowlist knob exists; see `.out-of-scope/dial-guard-subnet-allowlist.md`. The Decision bullet's "unless an allowlist entry admits them" describes a later slice, not D1.
- **No metric counter.** The shadow log line is what the 24 h measurement reads. A counter would be a second source for the same number.

### http behaviour changes (always on, the http guard has no `off`)

The classifier the http engine calls now refuses more. Everything the pre-G2 classifier refused is still refused (proptest `nothing_the_pre_g2_classifier_refused_is_now_allowed`). Newly refused:

- IPv4 multicast `224.0.0.0/4`.
- The whole reserved `240.0.0.0/4`. Before, only the broadcast `255.255.255.255` was refused.
- Benchmarking `198.18.0.0/15` and the IETF assignments block `192.0.0.0/24`.
- IPv4 embedded in IPv6 is judged as its IPv4 address. This covers IPv4-compatible `::a.b.c.d`, NAT64 `64:ff9b::/96` and 6to4 `2002::/16`. Before, only `::ffff:a.b.c.d` was decoded.
- IPv6 outside global unicast `2000::/3`, plus `2001::/23` (IETF protocol assignments), documentation `2001:db8::/32` and `3fff::/20`.
- The names `*.localhost`, and `localhost.` / `metadata.` / `instance-data.` with one trailing dot.

`DATA_PLANE_HTTP_ALLOW_INTERNAL=1` still turns the http check off. The http tests keep every assertion. Their module now reaches the classifier through a three-line test helper, and they are green.

### Caveats D1 ships with

- pgwire pins the first vetted address of each host. A host with several A records loses driver-level failover across them.
- MySQL re-vets every 30 s, at checkout, rather than at each connect. A DNS change reaches the pool up to 30 s late, and every connection still goes to a vetted address.
- `system_lookup` returns what the system resolver says at that moment. The pin closes rebinding between the check and the connect, but not a resolver that is itself compromised.
- Under enforce, the pgwire per-dial refusal surfaces as a generic tokio-postgres config error, because tokio-postgres has no public error constructor. The `dial_guard deny` log line names the class. The open-time refusal names it in the error too.

## D3a — Redis (C11)

Code lives in `data-plane-pool/src/redis/dial.rs`; the tests are `redis/dial_tests.rs`.

- **No TLS caveat.** The `redis` dependency has no TLS feature, so `rediss://` fails at parse and there is no SNI to keep. A `TcpTls` address is still refused, rather than trusting that.
- **Unix refused.** A `redis+unix://` DSN is refused under enforce and logged as `would_deny` (class `unix_socket`) under shadow, like MySQL's `socket=`.
- **Pinned.** Under enforce the guard dials `ConnectionAddr::Tcp(<vetted ip>, port)` with the parsed db, username, password and protocol unchanged; the driver never resolves the name. `off` and Platform DSNs open exactly as before.
- **Re-vet.** `ConnectionManager` has no per-connection hook. At checkout, at most every 30 s, the guard re-vets; it builds a new manager only when the pinned IP is no longer in the vetted set, then swaps it in. A failed connect keeps the old manager and the old pin.

### Caveats D3a ships with

- `ConnectionManager` reconnects on its own to the pinned IP. A DNS change reaches the mount up to 30 s late.
- Under shadow, a refused host logs once per re-vet interval, not once per connection.
