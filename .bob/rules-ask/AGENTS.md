# AGENTS.md — Ask mode

This file provides guidance to agents when working with code in this repository.

## Non-obvious documentation context

- **`claude-deal-with-the-devil/`** (git submodule at repo root) is the upstream source of the `.claude/` agent config. It is **not** an app migration target. Its tools, hooks, agents, skills and rules are merged into `.claude/` (grobase's versions of shared files kept).
- **`src/control-plane/`** is the Go plane — module `github.com/dlesieur/mini-baas/control-plane`. Its 44 `internal/` packages replaced the former `shared` junk-drawer; there is no `shared/` package.
- **`infra/docker/services/realtime/realtime-agnostic/`** is the Rust realtime workspace — plain tracked files (no nested `.git`).
- **`src/coverage/`** is generated lcov HTML — exclude from any grep/search of source code.
- **`vendor/` apps** are plain tracked directories (no submodules), each with a `GROBASE.md` or `GROBASE-MIGRATION.md`. `vendor/vault42` is ABSENT — vault42 runs as a published image.
- **`sdk*/` flat dirs no longer exist** — the TS SDK is `sdks/js/` (package `@grobase/js`). References to `sdk/` are stale.
- **`mini-baas-infra/` no longer exists** — the monorepo subtree was flattened to the repo root. References to `mini-baas-infra/src/…` are stale history.
- **`Makefile.bak`** is the pre-split 735-line monolith; the real Makefile is a thin orchestrator that includes every `orchestrators/makes/*.mk` fragment.
- **The polyglot SDKs' test stubs are empty `pass` bodies** — the build/compile is the real check, not `pytest`/`dart test`.
- **`ABAC`/`PERMISSION_CONDITIONS_ENABLED`/`API_KEY_ABAC_ENABLED` gates are TS/data-plane gates**, not Go `envBool` route-mount gates — look in `src/apps/permission-engine` and `src/apps/query-router`.
- **The `.claude/` folder** is intentionally kernel-less. It holds `rules/`, `agents/`, `skills/`, `commands/` (incl. `commands/workflow/` → `/workflow:<name>`), `workflows/`, `tools/`, `hooks/`, `doc/`, `scripts/`.
- **Root docs:** `QUICKSTART.md` (5-min bring-up), `DEPLOYMENT.md` (production), `SECURITY.md` (threat model), `RELEASE.md` (release process), `HUMAN-ATOMS.md` (GA checklist), `LICENSING.md` (open-core: core AGPL-3.0, SDKs MIT, enterprise commercial).
- **`prompt.md`** is the short start-here briefing for any agent; it points to `CLAUDE.md` for detail.
- **`AppFlowy` in `vendor/`** is committed as ~2880 plain tracked files (nested `.git` removed) with zero BaaS wiring — unintegrated playground.
- **`vendor/claude-deal-with-the-devil`** (if you see references to it) was the old misfiling of the agent config; it is now properly tracked as the `claude-deal-with-the-devil/` git submodule at the repo root.
- **Migration `062` is `062_tenant_entitlements.sql`** — trust the in-file header, not the filename.
- **`wiki/architecture/`** holds the architecture docs (org/team/group/RBAC design, service-boundaries); `deploy/` has `go-live/`, `fly/`, `helm/`, `kustomize/`, `ha/`.
