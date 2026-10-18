# 0003 — The WAF compresses an allowlist of data routes, nothing else

Status: accepted (2026-10-18, devil D2: allowlist only).

## Decision

`infra/docker/services/waf/conf/nginx.conf` keeps `gzip off` at server level and turns it on in
three locations only: `^/rest/v1/` except `^/rest/v1/rpc/`, `^/data/v1/`, `= /query/v1/execute`.
Level 4, `application/json` (+ PostgREST object/geo JSON, CSV), bodies over 1 KB.

A denylist was refused: auth tokens, `/v1/tenants/me/keys`, `/v1/auth/otp/verify`, escrow,
`/storage/v1/sign`, admin keys/secrets, `/functions/v1`, `/sessions/v1` and `/rest/v1/rpc/*` all
put a secret in a body that can sit beside reflected input (BREACH), and any route added later
would ship compressed by default.

## Measured (kept because it met the bar: ≥ 20 KB saved per open, WAF throttling not up)

| 293-page workspace, batched open | before | after |
|---|---|---|
| bytes per open | 66 KB | 18 KB |
| p50 / p95, 50 concurrent opens | 1803 / 3925 ms | 464 / 1320 ms |
| WAF throttled during the run | 783 ms | 718 ms |

`artifacts/bench/perf-osionos-{before,after}.json` (`TAG=… bash scripts/bench/osionos-fanout.sh`;
the after run also carries the keep-alive pool and the PERF=1 caps).

## Gate

`scripts/verify/m237-edge-compression.sh`: every literal Kong path prefix plus the sensitive
routes are probed with `Accept-Encoding: gzip`; only the allowlist may answer `gzip`, and a mutant
with server-level `gzip on` must be caught.

## Known limit

Table rows are compressed whatever they hold: a table storing a secret beside attacker-writable
text would be BREACH-readable over `/rest/v1`. Keep such columns out of client-readable tables.
