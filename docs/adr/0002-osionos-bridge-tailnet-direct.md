# 0002 — The osionos bridge may reach baas over the tailnet, after its conditions hold

Status: accepted with conditions (2026-10-18, devil D1). Supersedes the earlier "Funnel-only
link" ruling for the bridge → baas hop. **Not switched yet**: the bridge lives on c2r19s6, and
conditions C1–C6 are checked there before its URL changes.

## Why

| measure (2026-10-18) | value | source |
|---|---|---|
| bridge → baas via the Funnel relay | 200–700 ms warm, 3.5 s cold, per call | /btw session timings |
| `tailscale ping` baas → `osionos` | 2 ms, direct path | `tailscale ping -c 5 100.81.47.51` |
| 293-page workspace open, n1 shape, 200 ms simulated RTT | 121 s | `artifacts/bench/perf-osionos-after.json` (`TAG=after bash scripts/bench/osionos-fanout.sh`) |
| same, batched (3 round trips) | 0.65 s | same artifact |

The relay RTT multiplies every round trip; no server-side change moves it (the RTT legs did not
change between the before and after artifacts).

## Conditions (acceptance criteria)

| | condition | proof |
|---|---|---|
| C1 | the WAF logs `100.81.47.51`, not `172.18.0.1`, for a bridge request to `https://100.119.10.117:8443/waf-health` — else BLOCK until the publish stops going through docker-proxy for that path | WAF access log line |
| C2 | `/admin/v1`, `/meta/v1`, `/realtime/v1/publish` refused at the WAF unless `REMOTE_ADDR` is an operator address; m227 gains a tailnet-direct, an `osio-ide-sbx` and a forged `X-Real-IP` probe, all 403 with the service key | m227 |
| C3 | the bridge's direct-path traffic gets zero 2xx on any ip-restricted Kong path | bridge access log over one bench run |
| C4 | tailnet ACL grants `tcp:8443` on baas to the bridge tag (+ named operator devices) only; `nc -zv 100.119.10.117 8443` from an untagged device fails | ACL JSON pasted here |
| C5 | the bridge verifies baas's TLS (pinned cert/CA); no `rejectUnauthorized: false` / `NODE_TLS_REJECT_UNAUTHORIZED`; scheme `https` on 8443, never plaintext 8880 | grep of the bridge |
| C6 | Funnel stays as a fallback on connect failure only, logged and counted | bridge metrics |
| C7 | after-artifact over the direct path, n ≥ 3 per leg | `scripts/bench/osionos-fanout.sh` |

## Separate finding, open today

The IDE sandbox bridges (`osio-ide-sbx` 10.202.0.0/24, `osio-ide-egr` 10.202.1.0/24) can reach
`10.202.0.1:8443` and `:8880`; Kong sees a private address, so admin routes rest on the ACL plus
the service key alone. This holds whether or not this ADR is applied; it is tracked on its own.
