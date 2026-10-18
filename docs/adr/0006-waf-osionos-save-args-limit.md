# 0006 — Raising the WAF argument limit for the osionos object-database save: not possible as ruled

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-19), **not applied** — its condition C1 failed.

## Problem

`POST /rest/v1/osionos_object_databases?on_conflict=owner_id,db_key` is refused by nginx with a
400 (rule 200007, "Failed to fully parse request body due to large argument count") on every load:
a 135-page database carries 1,096 JSON values, `MODSEC_ARGUMENTS_LIMIT=1000` (`waf/Dockerfile`).
Kong never sees it.

## Measured cost of parsing (hermetic WAF, 1 CPU, p50 of 15)

| JSON values | body | WAF time |
|---|---|---|
| 800 | 10 KB | 130 ms |
| 1,100 | 14 KB | 183 ms |
| 2,000 | 26 KB | 323 ms |
| 4,000 | 53 KB | 752 ms |
| 7,000 | 92 KB | 1,304 ms |

The WAF runs before Kong's auth, so a global raise is a pre-auth CPU lever. The ruling allowed
2,000 on one exact-match location behind a write rate limit (12/min, burst 3).

## Why it was not applied

C1 (a 1,096-value save passes on that location) failed: `modsecurity_rules 'SecArgumentsLimit
2000'` inside `location = /rest/v1/osionos_object_databases` leaves the request refused — the
connector keeps the http-level limit when it merges the location's rules. The global limit did not
leak (1,100 values to four other paths: 400). The rate limit itself worked (4 pass, 5th 429; GETs
uncounted). The change was reverted.

## Decision

Fix it in the app: a save sends only the pages that changed, nothing when nothing changed, never
retries a 4xx on later loads, and splits anything larger into requests under 1,000 values (or
stores one row per page). Zero server cost.

## Reopen when

The app cannot stay under 1,000 values per request. Then the route-scoped raise needs the limit
moved out of the http-level config into every sibling location (an image template change), proven
by the same C1/C2 probes.
