# Troubleshooting

The short list, in the order problems actually happen.

## Stack won't start

```sh
make doctor          # environment sanity (docker, compose, ports, env)
make ps              # what's running / restarting
make logs-<plane>    # e.g. make logs-data — follow one plane's logs
```

- **Port already in use** — `scripts/resolve-ports.sh` runs automatically inside
  `make up` and picks free host ports. If something still collides:
  `lsof -i :8000` to find the squatter.
- **Stale containers from an old shape** — also automatic (`_rm-stale` inside
  `make up`). Manual reset: `make down && make up PACKAGE=<tier>`.
- **`.env` missing or half-generated** — `make env` (refuses to overwrite;
  `FORCE=1 make env` regenerates from scratch — this rotates ALL local secrets).

## Gateway answers 401

Every public route needs the anon API key:

```sh
APIKEY=$(grep '^KONG_PUBLIC_API_KEY=' .env | cut -d= -f2)
curl http://localhost:8000/auth/v1/health -H "apikey: ${APIKEY}"
```

No header → Kong 401 by design (fail-closed). Data-plane calls additionally take
`X-Baas-Api-Key: <tenant key>`.

## Gateway answers 503 / slow first minute

First boot pulls images and runs migrations; the gateway is healthy when
`make health` shows both probes green. Budget ≤ 90 s on a warm machine
(`make bench-startup` measures yours).

## Where is my data?

Named Docker volumes — they survive `make down`:
`postgres-data`, `mongo-data`, `redis-data`, `minio-data`, `nano-data`, `one-data`, …
`docker volume ls | grep mini-baas`. Deleting data is always explicit
(`docker compose down -v`) — no Makefile target does it for you.

## Tenant provisioning hangs after a data-plane restart

Recreating the data-plane container gives it a new IP; tenant-control caches the
old one. `docker restart mini-baas-tenant-control` (and `mini-baas-kong` if Kong
was up before the recreate) re-resolves DNS.

## binocle (single binary)

- **Lost the admin key** — it prints on FIRST boot only. Stop the binary, move
  `./data` away, restart for a fresh key (or mint a new key with the old one if
  you still have a session).
- **Port busy** — `DATA_PLANE_ROUTER_PORT=8091 ./binocle-one`.

## Still stuck

`make verify-all` pinpoints which subsystem is unhappy (gates print PASS/FAIL
per milestone). Attach the failing gate's output plus `make ps` to an issue.
