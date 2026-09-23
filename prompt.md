# Grobase — start here

The briefing for any agent (Claude Code, Bob, or another) starting work in this repo.
It is deliberately short and holds **no counts, versions or backlog** that drift —
those live in the files it points to. **`CLAUDE.md` is the authoritative orientation.**

## 1. What this is

Grobase is a self-hostable Backend-as-a-Service: one backend (auth, database, realtime,
storage, functions) for any frontend, with no per-project server code. It runs as OSS
self-host, as a managed cloud, and as an enterprise platform — all from one codebase,
with every cloud/enterprise behavior **flag-gated OFF by default**.

| Plane | Language | Path |
|---|---|---|
| Application | TypeScript / NestJS | `src/apps/`, `src/libs/` |
| Control | Go | `src/control-plane/` |
| Data | Rust | `src/data-plane-router/` |
| Realtime | Rust (vendored, tracked) | `infra/docker/services/realtime/realtime-agnostic/` |

The load-bearing seam: the Go control plane resolves an API key to an identity
(`POST /v1/keys/verify`); the Rust data plane executes the query and owner-scopes it
**per request** with that identity (never by pool state).

## 2. Read before writing code

1. `CLAUDE.md` — layout, commands, editions/packages, flag tables, gates, binding rules.
2. `.claude/rules/` — the code rules. The always-on ones (minimalism ladder + markers,
   comments, no-globals, refactor-common, service-boundaries, risk, quality-bar, …)
   load every session; the language ones (`refactor-go`, `refactor-rust`, …) load when
   you touch a matching file.
3. `.claude/AGENTS.md` — how to fan out subagents here (and converge).

## 3. Non-negotiables (full text in `CLAUDE.md` → "Binding rules")

- No `Co-Authored-By` / "Generated with" trailers on commits or PRs.
- New behavior is flag-gated OFF by default; a missing env var must equal today's behavior.
  Cross-plane features need **both** planes' flags (e.g. `METERING_ENABLED` AND `DATA_PLANE_METERING`).
- Engine-agnostic: a fix for one engine adapter that breaks another is not done.
- Shadow → parity → cutover → delete for the TS→Rust migration. UNKNOWN = FAIL.
- Measured, not claimed: a performance statement cites an artifact and the command that made it.
- Confirm the irreversible (push, deploy, delete, publish, RS256 cutover) with a human.
- grobase owns all state; apps are contracts (`infra/config/contracts/<app>.json`), never code.
- **Never paste a secret into a doc, prompt or memory** — `make check-secrets` scans docs too.

## 4. Build, test, verify — Docker-first

```bash
make quickstart                  # first run: .env → up → health
make build                       # most services pull a prebuilt GHCR image otherwise
make test-lint                   # shell·rust·go·ts·yaml·docker·make·compose, all in Docker
make test-scan                   # secrets (incl. gitleaks over docs) + semgrep/trivy/npm audit
make audit-deps                  # cargo-audit + govulncheck
make nestjs-ci                   # TS: tsc + eslint + jest
bash scripts/verify/m<NN>-*.sh   # one numbered gate; run-gate-battery.sh --fast for the PR set
```

One Go test, from `src/control-plane/`:
`docker run --rm -v "$PWD":/src -w /src golang:1.25-bookworm go test ./internal/<pkg> -run TestX -v`.
Other planes' single-test forms are in `CLAUDE.md`. A gate that passes vacuously is not a gate.

## 5. Tools you have

- **`.claude/tools/*.sh`** (run from the repo root): `digest` (briefing; the SessionStart
  hook injects it), `facts`, `preflight`, `codemap`, `untested`, `dupes`, `quality`,
  `watch` (run long commands under `watch.sh --idle 60 --`), `selfcheck` (run after
  editing `.claude/`), `context`, `ponytail`, `scripts`.
- **Commands:** `/prompt`, `/quality`, `/refactor`, `/bench`, `/migrate`, `/audit-bloat`,
  `/slim`, `/compat`, `/changelog`, and the playbooks `/workflow:<feature|harden|deal|
  migrate-db|ship|compat-audit|onboard-app|perf-sprint>`.
- **Agents:** `devil` (risk verdict before risky work), `architect`, `security`,
  `reviewer`, `builder`, `forger`, `innovator`, `benchmarker`, `compat-tester`,
  `norminette`, `documenter`.
- **MCP servers** (root `.mcp.json`): `grafana` and `postgres` are read-only views of the
  **local** stack (Prometheus/Loki queries, schema/EXPLAIN) via `scripts/ops/mcp-server.sh`;
  `playwright` drives a browser; `context7`/`deepwiki` fetch library docs;
  `supermemory` sends what you store to supermemory.ai — never store secrets there.

## 6. Current state — where to look, not what to believe

- Security findings and their status: `wiki/security/remediation-tracker-2025-07-14.md`
  (the evidence is in `vulnerability-report-2025-07-14.md`). Treat each claim as a
  hypothesis: re-verify against the code before acting on it.
- Tool baseline (what the lint/scan/audit matrix currently reports):
  `artifacts/quality/baseline-2026-09-23.md` (local; regenerate with the make targets above).
- GA checklist of human/money/account actions: `HUMAN-ATOMS.md`.

## 7. Gotchas that cost time

- `docker compose up` pulls `:latest` images for services marked `# pull-fallback` —
  local edits are invisible until you build that service.
- The TS SDK (`sdks/js/`) tests with `node:test`, not jest.
- In a Claude Code shell, `grep` is a wrapper that **skips gitignored files**; use
  `/usr/bin/grep` when you need to search `.env*`, `artifacts/` or other ignored paths.
- `src/coverage/` is generated HTML — exclude it from searches.
- Hooks and permissions live in `.claude/settings.json`; changes there are applied by a
  human, not by an agent.
