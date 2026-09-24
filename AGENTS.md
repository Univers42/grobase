# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## What this repo is

Grobase (`github.com/Univers42/grobase`) — a self-hostable BaaS. **Three-language stack:** TypeScript/NestJS (`src/apps/` + `src/libs/`), Go 1.25 (`src/control-plane/`), Rust (`src/data-plane-router/`; realtime at `infra/docker/services/realtime/realtime-agnostic/`).

The `.claude/` config's upstream is the external upstream repo [`Univers42/claude-deal-with-the-devil`](https://github.com/Univers42/claude-deal-with-the-devil) (not vendored here — no submodule). Its tools, hooks, extra agents (`builder`, `forger`, `innovator`), skills and rules are **merged into `.claude/`** (grobase's own versions of the files both trees share were kept). Run `bash .claude/tools/selfcheck.sh --summary` after editing `.claude/`; hooks live in `.claude/settings.json`, MCP servers are declared in the upstream's `.mcp.json` (copy it locally to opt in; none is committed here).

## Build/Run — Docker-first (no host toolchains)

All builds and lifecycle go through the root `Makefile`. **Never invoke node/cargo/go on the host.**

```bash
make quickstart                     # generate .env → up → health (first run)
make up EDITION=query               # bring up a named plane set
make build                          # build all images (required before local changes take effect — see GHCR gotcha)
make migrate                        # run PostgreSQL migrations (forward-only, non-contiguous numbering)
make test-lint / test-scan / audit-deps   # lint matrix · secret+SAST scan · dependency CVEs (all in Docker)
make doctor / make health / make ps
```

## Build/lint/test per plane

| Plane | Suite | Single test |
|---|---|---|
| **TS app** (NestJS · Jest; 16 spec files across `src/apps/` + `src/libs/`) | `make nestjs-ci` = `tsc --noEmit` + eslint + jest | `docker run --rm -v "$PWD/src":/app -w /app -v mini-baas-src-node-modules:/app/node_modules node:20-alpine npx jest <spec> -t '<case>'` |
| **Go control** | `make go-control-plane-check` | from `src/control-plane/`: `docker run --rm -v "$PWD":/src -w /src golang:1.25-bookworm go test ./internal/<pkg> -run TestX -v` |
| **Rust data** | `make rust-data-plane-test` | `cargo test -p data-plane-core <name>` via the data-plane CARGO wrapper |
| **Rust realtime** | `make rust-realtime-test` | `cargo test -p realtime-core <name>` via realtime CARGO wrapper |
| **TS SDK** (`sdks/js/` · **node:test, NOT jest**) | `cd sdks/js && npm run build && npm test` | `node --test tests/<name>.test.mjs` (or `--test-name-pattern='<re>'`) |

## Verify gates — the unit of "done"

Every feature lands behind a numbered gate `scripts/verify/m<NN>-*.sh` (`ls scripts/verify/m*-*.sh` for the current set and the next free number). A gate that passes vacuously (no-op) is **not** a gate.

```bash
bash scripts/verify/m80-quota-enforce.sh
bash scripts/verify/run-gate-battery.sh --fast        # per-PR subset
bash scripts/verify/run-gate-battery.sh --enterprise  # nightly battery
```

After any API change: update `infra/config/openapi/grobase-public.json` and regenerate SDKs (`cd sdks/js && npm run codegen:all`).

## Critical gotchas

- **GHCR pull-fallback:** every compose service with a `# pull-fallback` line (`grep -rc pull-fallback orchestrators/compose/base`) carries `image: ghcr.io/univers42/grobase-<svc>:latest` above its `build:` block — `docker compose up` **pulls prebuilt images, not local source**. Run `make build` to pick up local changes.
- **Flag AND pattern:** features spanning Go + Rust/TS planes need BOTH planes' flags truthy (e.g. `METERING_ENABLED` AND `DATA_PLANE_METERING`). Flipping only one is a silent no-op. All new behavior must be flag-gated OFF by default.
- **TS→Rust cutover is per-request, not a build flag:** `RUST_DATA_PLANE_FORWARD=1` (TS-side) is independent of `DATA_PLANE_ROUTER_PRODUCT_MODE` (Rust-side, default `shadow`).
- **`src/coverage/`** is generated lcov HTML — exclude from grep/search.
- **`make parity`** errors out (exit 1) without `NEW=<url>` — not a silent no-op.
- **`make up PACKAGE=nano`** is invalid — use `make nano-up`.
- **`make fclean`** requires `CONFIRM=1`; wipes only this project's data volumes.
- **`.env` is never auto-clobbered** — `scripts/env/generate-env.sh` refuses without `FORCE=1`.
- **`infra/docker/services/realtime/realtime-agnostic/`** is vendored as plain **tracked** files (no nested `.git`).
- **`sdks/js/src/generated/`** is gitignored except the committed `engines.ts` — regenerate with `npm run codegen:all`.
- **`vendor/vault42` is absent** — vault42 runs as a published image via the `vault42` compose plane.
- **`claude-deal-with-the-devil`** is the external upstream of the `.claude/` config (not in this repo); **not** an app migration target.

## Binding code style rules (from `.claude/rules/`)

**Minimalism ladder:** YAGNI → stdlib → platform → existing dep → one-liner → minimum. Performance on hot paths overrides; document with `// perf: …`. Hierarchy: `correctness > performance > minimalism > readability > style`.

**Markers:** deliberate shortcuts → `// ponytail: <what> — <upgrade path>`; perf overrides → `// perf: <why>`. These are the ONLY in-body comments tolerated.

**Comments:** no prose inside function bodies — all commentary belongs in the doc comment ABOVE the declaration. Only `// ponytail:`, `// perf:`, `// SAFETY:` are permitted in-body.

**No globals:** no package-level `var` (Go), no module-scope mutable binding (TS), no `static mut`/`lazy_static` (Rust). Only Go `//go:embed` targets are exempt.

**Structural (all languages):** max 40 lines/function (Go: ≤25 lines body, ≤5 funcs/file); max 300 lines/file; max 4 data params (Go: `ctx` and receiver don't count); max 3 nesting levels.

**Go:** `gofumpt -l -w .` (not `gofmt`); package by domain/capability — **no** `utils`/`common`/`helpers`/`shared`; accept interfaces, return structs; `ctx` always first; hexagonal (ports in domain, adapters implement ports, domain never imports infra types).

**Rust:** `Result<T,E>` everywhere, no `unwrap()` outside tests; `thiserror` for library errors, `anyhow` for binary errors; `// SAFETY:` above every `unsafe` block; `cargo clippy -- -D warnings` clean.

**TypeScript:** no `any` (use `unknown` + type guard); no enums (use `const` objects with `as const`); named exports only; no barrel `index.ts`; prefer `type` over `interface` unless extending; `??` over `||`; `tsc --noEmit` + `eslint . --max-warnings 0` clean.

**Naming:** behavior not implementation; no single-letter names outside loops; consistent vocabulary; commit format: `refactor(<scope>): <what> — <which rule>`.

## Service boundaries (binding)

- **grobase (fly.io) owns ALL state** — DB, auth, OTP, realtime, files
- **Vercel hosts only stateless frontends** + optional same-origin rewrite (never a BFF)
- **WebSocket: browser → fly directly** — never through Vercel
- **grobase contains zero app-specific code** — apps are declarative contracts at `infra/config/contracts/<app>.json`
- **Never co-author commits** (no `Co-Authored-By` / "Generated with" trailers)
- **Confirm the irreversible** (pushes, deploys, deletions, npm publish, RS256 cutover) — explicit human trigger
