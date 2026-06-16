# OpenAPI specs (A3 — codegen source)

This directory was empty (only `.gitkeep`), which **blocked all multi-language
SDK codegen** (Track A4). It is now populated two ways:

## 1. `grobase-public.json` — hand-authored, canonical (A4 codegen source)

A single **OpenAPI 3.1** document describing the five **public, Kong-fronted**
surfaces a client SDK consumes, at the exact paths `sdk/src/core/routes.ts`
targets:

- `/auth/v1` — gotrue (password, OAuth `authorize`, MFA `factors`)
- `/rest/v1` — PostgREST auto-REST (+ `rpc`)
- `/storage/v1` — storage-router (object/list/sign/bucket)
- `/query/v1` — engine-agnostic data plane (execute/txn/schema/engines)
- `/functions/v1` — Deno edge functions

Validated structurally (`@readme/openapi-parser`): **25 paths / 32 operations**.

**Why hand-authored, not collected:** the collected per-service docs (below)
describe each NestJS service at its *internal* port and path, not the public
Kong prefix; and the core surfaces are **not** NestJS at all — `auth` is gotrue
(Go), `rest` is PostgREST, `functions` is a Deno runtime. None of those three
emit a `/docs-json`, so collection alone cannot produce the public spec a
polyglot SDK needs. This document is the canonical codegen input.

## 2. Collected per-service docs (live `/docs-json`, supplementary)

Collected read-only from the running stack (2026-06-13) via the existing
`openapi-collect.sh` mechanism (here run from inside the docker network):

- `storage-router.json` — internal storage-router (`/storage/v1/...`, ports/health)
- `query-router.json` — internal query-router data plane (`/{dbId}/...`, `/txn`, `/engines`)
- `permission-engine.json` — internal permission-engine

Only these three NestJS services expose `/docs-json` in the running edition;
the other services in `openapi-collect.sh`'s port map were not on the network in
this profile. These are kept as live evidence and for per-service typed clients
(`npm run codegen`), but `grobase-public.json` is the source of truth for A4.

## Regenerate

```bash
# Collected docs (stack must be up; reads only, never mutates the stack):
bash mini-baas-infra/scripts/openapi-collect.sh --docker-network   # from inside the network
# Validate the hand-authored public spec:
npx @readme/openapi-parser validate mini-baas-infra/openapi/grobase-public.json
```
