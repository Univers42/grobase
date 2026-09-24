# AGENTS.md — Agent (coding) mode

This file provides guidance to agents when working with code in this repository.

## Non-obvious coding rules

- **Docker-first, always.** Never run `node`/`cargo`/`go` on the host for lifecycle tasks — all toolchain invocations run inside Docker via root `Makefile` targets.
- **GHCR pull-fallback trap:** `docker compose up` pulls prebuilt `:latest` images for every compose service with a `# pull-fallback` line (`grep -rc pull-fallback orchestrators/compose/base`), not local source. Always `make build` before testing local changes.
- **TS SDK uses `node:test`, not jest/vitest** — `sdks/js/` tests run with `node --test tests/<name>.test.mjs`.
- **16 TS spec files are spread across `src/apps/` (12) and `src/libs/common/` (4)** — single-test invocation needs the exact spec path.
- **`sdks/js/src/generated/` is gitignored except `engines.ts`** — regenerate with `cd sdks/js && npm run codegen:all` after any API change; `engines.ts` is committed as the SDK's contract.
- **Minimalism markers are required:** deliberate shortcuts → `// ponytail: <what> — <upgrade path>`; perf overrides → `// perf: <why>`. These are the ONLY in-body comments tolerated (plus `// SAFETY:` for Rust unsafe).
- **No in-body prose comments** — all commentary belongs in the doc comment ABOVE the declaration.
- **No globals, ever** — no package-level `var` (Go), no module-scope mutable binding (TS), no `static mut`/`lazy_static` (Rust). Only Go `//go:embed` targets are exempt.
- **Go: `gofumpt` not `gofmt`** — `gofumpt -l -w .` is the formatter; plain `gofmt` is insufficient.
- **Go: ≤5 funcs per file, ≤25 lines per function body**. `ctx context.Context` and method receiver do NOT count toward the 4-parameter limit.
- **Go: no `utils`/`common`/`helpers`/`shared`** package names — package by domain/capability only.
- **Rust: `thiserror` for library errors, `anyhow` for binary errors.** Every `unsafe` block requires `// SAFETY:`.
- **TS: no `any`, no enums, no default exports, no barrel `index.ts`** — use `unknown` + type guards, `const` objects with `as const`, named exports.
- **Flag AND pattern:** features spanning Go + Rust/TS planes each need BOTH flags truthy — flipping one is a silent no-op. New behavior MUST be flag-gated OFF by default.
- **Every new feature needs a verify gate** `scripts/verify/m<NN>-*.sh`. A gate that passes vacuously is not a gate.
- **After any API change:** update `infra/config/openapi/grobase-public.json` and regenerate SDKs.
- **Migrations are forward-only** (forward-only, non-contiguous numbering — `ls scripts/migrations/postgresql` for the current set). Never roll back — gate the new code first.
- **`make fclean` requires `CONFIRM=1`** — guards against accidental data-volume wipe.
- **grobase contains zero app-specific code** — apps are declarative contracts at `infra/config/contracts/<app>.json`. Never hardcode app logic into grobase.
- **Never co-author commits** — no `Co-Authored-By` / "Generated with" trailers.
- **Confirm before any irreversible action** (pushes, deploys, npm publish, RS256 cutover).

## The `.claude/` agent config and the submodule

The `.claude/` config's upstream is the external upstream repo [`Univers42/claude-deal-with-the-devil`](https://github.com/Univers42/claude-deal-with-the-devil) (not vendored here — no submodule). Its tools, hooks, extra agents (`builder`, `forger`, `innovator`), skills and rules are **merged into `.claude/`** (grobase's own versions of the files both trees share were kept). Run `bash .claude/tools/selfcheck.sh --summary` after editing `.claude/`; hooks live in `.claude/settings.json`, MCP servers are declared in the upstream's `.mcp.json` (copy it locally to opt in; none is committed here).
