# 0028 — Redis ACL password, stage 1: an `app` user beside the default user (opt-in)

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-30, G5 RA1–RA11). Opt-in (`REDIS_ACL=1`);
nothing deployed, no VM change.

## Problem

G5 asks for "Redis TLS port + ACL password". G5b (ADR 0012) and D3 (ADR 0024) delivered the
TLS half. The password half did not exist: no `requirepass` anywhere (the "see prod compose"
note in `orchestrators/compose/base/data-engines.yml` points at nothing), `REDIS_PASSWORD`
was never minted, and every consumer dials the passwordless default user. On the VM,
2026-10-30, `CLIENT LIST` showed 5 connections, all `user=default`.

Two redis-cli traps, measured on 7.2.11, shape the design. `redis-cli ping` exits 0 on
NOAUTH. With a wrong password, redis-cli prints WRONGPASS and then PONGs as default. So a
healthcheck that greps PONG proves nothing once auth matters.

## Decision

- **Its own knob, its own file (RA1).** `REDIS_ACL=1` (env, or `.env.local`) composes
  `orchestrators/compose/docker-compose.redis-acl.yml` (`orchestrators/makes/00-config.mk`).
  `ENGINE_TLS` and `ENGINE_TLS_ENGINES` never compose it. The default render is
  byte-identical whether or not `REDIS_PASSWORD` is in `.env` (m261 compares the two).
- **One ACL user, `app`, beside the default user (RA2, RA9).**
  `infra/docker/services/redis/redis-acl.sh serve` computes the sha256 of the password in the
  compose secret `redis_acl_password` (sourced from `REDIS_PASSWORD`) and execs
  `redis-server … --user app on #<sha256> ~* &* +@all` as separate argv tokens. The default
  user stays `on nopass`. Neither the password nor its hash is in `docker inspect`: the hash
  is computed inside the container, and redis rewrites its process title. `serve` refuses an
  empty secret. There is one user for every consumer, with no per-consumer ACLs.
- **A minted secret (RA3).** `scripts/env/generate-env.sh` mints `REDIS_PASSWORD`
  (`openssl rand -hex 32`) and lists it in `GENERATED_KEYS`. `assemble-env.sh` runs
  `generate-env.sh --topup`, which adds the key to an existing `.env.secrets`. It is classified in
  `infra/config/env/schema.json`: SECRET, optional, compose-required, `redis/REDIS_PASSWORD`.
- **Every consumer gets the login (RA4).** The overlay sets `redis://app:${REDIS_PASSWORD}@redis:6379`
  on every `*REDIS*_URL` a service already declares in the base files: 13 names, 57
  (service, name) pairs. No service gains a new name. Debezium gets
  `DEBEZIUM_SINK_REDIS_USER` / `DEBEZIUM_SINK_REDIS_PASSWORD`, which map to
  `debezium.sink.redis.user` / `.password` (`RedisCommonConfig`, debezium-storage-redis
  3.0.0.Final). outbox-relay's two code defaults now read the env through
  `@mini-baas/common` `redisUrlFrom` (`src/libs/common/src/config/redis-url.ts`):
  `outbox-relay.service.ts` reads `REDIS_URL` then `OUTBOX_REDIS_URL`, the saga coordinator
  reads `OUTBOX_REDIS_URL` then `REDIS_URL`, and the fallback stays the credential-free
  `redis://redis:6379`. No credential is hard-coded.
- **A healthcheck that can fail (RA5).** `redis-acl.sh health` sends `PING` and `ACL WHOAMI`
  as app and passes only on the exact reply `PONG` / `app`. A wrong password falls back to
  default, answers `default`, and fails.
- **Composes with the TLS overlay (RA10).** The TLS overlay owns redis' entrypoint, user,
  env, cert mount and tmpfs. This overlay owns its command, healthcheck, secret and script
  mount. The two orders render the same apart from the order of the volume list. The TLS
  wrapper appends `--tls-port …` to the command, so `serve` passes it through.
- **Tools follow (RA11).** `grobase-import-rebind.sh` still reads `--requirepass`. Failing
  that, it reads the one `redis://USER:PASSWORD@redis` login carried by running containers'
  `*REDIS*_URL` values. It refuses two different logins, and refuses an ACL redis with no
  login. `stack-health-requests.sh` leg 4 checks the env file's `REDIS_PASSWORD` through
  `redis-acl.sh health` when the overlay is up, and runs the legacy ping otherwise.

## Caveats

- **Stage 1 serves a wrong password.** The default user is still `on nopass`, so a consumer
  with a missing or wrong password is served as default and looks healthy. Only stage 2
  (`ACL SETUSER default off`) makes a mis-wired consumer fail. The count that tells you
  stage 2 is safe is `CLIENT LIST` with 0 `user=default` on the real stack.
- **The URL carries the password.** Consumer containers hold it in their env, as
  `DATABASE_URL` does for postgres, so `docker inspect` of a consumer shows it. Only redis'
  own inspect is free of it.
- **An operator-set URL is overridden.** A `REDIS_URL` set in `.env` is replaced by the
  overlay value, not merged with it.
- **Empty values gain meaning.** On data-plane-router and realtime, an empty
  `*_METERING/QUOTA/RATELIMIT/PRESENCE_REDIS_URL` meant "no sink" when its flag was on. Under
  the overlay these values are set. Every such flag is off by default.
- **Clients behave differently on a wrong password (m261).** go-redis 9.20.0 returns
  WRONGPASS, but the refused socket stayed open as `user=default` (`cmd=auth`) after
  `client.Close()` for as long as the process lived. m261 therefore runs that dial in its
  own process. ioredis 5.11.0 emits WRONGPASS on `error`, rejects `connect()` with
  "Connection is closed.", and closes the socket. Debezium 3.0.0 logs WRONGPASS and holds no
  connection.
- **The rebind reads userinfo as written,** without percent-decoding. A minted hex password
  needs no decoding.

## Not done

- **Stage 2 (RA6).** `ACL SETUSER default off` / `--user default off` needs its own ruling.
  Before it can happen, every `user=default` connection on the VM has to be accounted for.
  On 2026-10-30 one of them came from an IP outside redis' network.
- **Tenant mounts.** The seed (`scripts/seed/multidb-workspace-engines.sh:84`) and m27
  (`m27-conformance.sh:148`) register `redis://redis:6379`. Under stage 1 those mounts dial
  default and keep working (RA8). The rebind keeps a DSN with no user as it is. Stage 2 has
  to rewrite both.
- **Not wired.** `scripts/env/bootstrap-env.mjs` and `scripts/vault/vault-env.mjs` do not
  list `REDIS_PASSWORD`. They do not list the MySQL/MSSQL passwords either. A vault42 push
  of the new key is an operator step.
- **Not exercised.** The Rust redis crate (realtime, data-plane-router) is not exercised by
  m261. Its features sit behind flags that are off by default. The stack's own services are
  not booted: their fixed `container_name` values collide with a running stack. Each client
  library is fed the value rendered for a real consumer instead (go-redis:
  webhook-dispatcher's `WEBHOOK_REDIS_URL`; ioredis: outbox-relay's `OUTBOX_REDIS_URL`;
  Debezium: its sink env).
- **No VM or `:8443` change (RA7).**

## Evidence

`bash scripts/verify/m261-redis-acl.sh` (CI job `redis-acl`) passed locally on
2026-10-30 against `m261-local/grobase-redis:ci`, built from this tree. It checks:

- static: the default render is identical with and without the key, and make composes the
  overlay only on `REDIS_ACL=1`;
- static: 57/57 pairs over 13 names are credentialed, and the Debezium sink is set;
- static: the command is restated exactly, and the redis render carries the secret 0 times;
- static: ACL+TLS ≡ TLS+ACL;
- static: the rebind fixtures pass;
- live: `docker inspect` carries the password 0 times and its hash 0 times;
- live: health fails a wrong password, while plain `redis-cli --user app ping` with that
  password still greps PONG (exit 0);
- live: `serve` refuses an empty secret, and `redis://redis:6379` PONGs as default;
- live: go-redis, ioredis and Debezium refuse a wrong password and hold one `user=app`
  connection each;
- live: `CLIENT LIST` shows `user=default` 0 times;
- live: under TLS+ACL, redis is healthy, has `tls-port` 6380, and app logs in over TLS.
