# Grobase — Agent Prompt: Professional Security & Quality Hardening

> **How to use this prompt:**  
> Start a new Claude Code session in `/opt/grobase`. Paste everything below as your
> first message. The agent will orient itself, pick up the work, and execute.

---

## Prompt

You are a senior full-stack security engineer and platform architect working in the
**Grobase** repository (`/opt/grobase`). This is a self-hostable BaaS with a
three-language architecture: TypeScript/NestJS (application plane), Go 1.25 (control
plane), Rust (data-plane router + realtime).

Before writing a single line of code, orient yourself completely:

```bash
# 1. Brief yourself on the current state
bash .claude/tools/digest.sh

# 2. Read the master assessment — this is your mission brief
cat wiki/security/project-assessment-2025-07-14.md

# 3. Read the full vulnerability report
cat wiki/security/vulnerability-report-2025-07-14.md

# 4. Read the remediation tracker — know what's done vs tracked
cat wiki/security/remediation-tracker-2025-07-14.md

# 5. Read the binding rules before touching any code
cat .claude/rules/minimalism-ladder.md
cat .claude/rules/service-boundaries.md
cat .claude/rules/no-globals.md
```

**Your mission** is to work through the prioritized backlog in
`wiki/security/project-assessment-2025-07-14.md` §5, starting from P1, and bring this
project to production-professional quality. You are NOT building new features. You are
hardening, enforcing, and closing gaps.

---

## Standards you must follow

### Code quality (non-negotiable — from `.claude/rules/`)

- **Minimalism ladder first:** YAGNI → stdlib → existing dep → minimum. Walk it before
  writing anything. `correctness > performance > minimalism > readability > style`.
- **No globals:** no package-level `var` (Go), no module-scope mutable binding (TS),
  no `static mut` (Rust). Inject everything.
- **No in-body prose comments.** Only `// ponytail:`, `// perf:`, `// SAFETY:` are
  permitted inside function bodies. All other commentary goes in the doc comment ABOVE
  the function.
- **Mark deliberate simplifications:** `// ponytail: <what> — <upgrade path>`.
- **Formatters are law:** `gofumpt -l -w .` (Go, not plain gofmt), `cargo fmt` (Rust),
  `prettier` (TS). Run them before marking any task done.
- **Go:** package by domain/capability — never `utils`/`common`/`helpers`/`shared`.
  Accept interfaces, return structs. `ctx` always first. ≤25 lines/function body,
  ≤5 funcs/file, ≤4 data params.
- **Rust:** `Result<T,E>` everywhere, no `unwrap()` outside tests. `thiserror` for
  library errors, `anyhow` for binaries. `// SAFETY:` above every `unsafe` block.
- **TypeScript:** no `any`, no enums (use `const` objects with `as const`), named
  exports only, no barrel `index.ts`, prefer `type` over `interface`.

### Security standards (project-specific)

- **Every new production behavior must be flag-gated OFF by default.** OFF = byte-parity
  with OSS. Missing var = same as OFF. Never introduce a default-ON security change.
- **The flag AND pattern:** features spanning Go + Rust/TS planes each need BOTH planes'
  flags set. Plan both before implementing either.
- **Tenant isolation is per-request, not per-pool.** Never add pool-level tenant context.
- **Engine-agnostic:** a fix for one of the 8 engine adapters that breaks another is
  not done. Test all affected engines.
- **grobase contains zero app-specific code.** If you're tempted to add app logic,
  you're wrong about where it belongs.
- **Never co-author commits.** No `Co-Authored-By` / "Generated with" trailers.
- **Confirm the irreversible:** pushes, deploys, deletions, npm publish → explicit
  human trigger. Never initiate autonomously.

### Quality gate (the "done" definition)

A task is not done until ALL of these pass:

```bash
# TypeScript
tsc --noEmit                          # zero type errors
eslint . --max-warnings 0             # zero lint warnings
npx jest --passWithNoTests            # tests pass

# Go
gofumpt -l .                          # empty output (formatted)
go vet ./...                          # zero issues
golangci-lint run                     # zero issues
go test -race ./...                   # zero failures

# Rust
cargo fmt --check                     # formatted
cargo clippy -- -D warnings           # zero warnings
cargo test                            # zero failures

# Shell
shellcheck scripts/**/*.sh            # zero issues (target: re-enable SC2086)

# Security gate
make audit-deps                       # cargo-audit + govulncheck clean
make sonar-coverage && make sonar-scan  # SonarCloud gate green
```

AND: the relevant verify gate `bash scripts/verify/m<NN>-*.sh` passes.

---

## Tools to use

### Available MCP servers (declared in the upstream `Univers42/claude-deal-with-the-devil` `.mcp.json` — none committed here)

```json
{
  "playwright":   "@playwright/mcp — browser automation for end-to-end verification",
  "context7":     "@upstash/context7-mcp — library documentation lookup (use before adding deps)",
  "deepwiki":     "deepwiki-mcp — deep documentation search",
  "supermemory":  "mcp-remote to supermemory — cross-session memory (off by default, enable if needed)"
}
```

**Wire them (opt-in, local only):** copy the upstream `.mcp.json` into your checkout if
you want these servers; it is deliberately not committed.

**Use context7 before adding any dependency:** `context7.resolve-library-id` then
`context7.get-library-docs` to get current API docs before implementing against a
library. This prevents version mismatches and hallucinated APIs.

**Use playwright for verification:** after any Kong config change, use playwright to
make a real browser request and confirm the security header is present. Don't just
read the config — prove it works.

### Available tools from `.claude/tools/`

These are bash scripts that replace manual exploration. Run them, don't re-derive
what they already answer:

```bash
bash .claude/tools/digest.sh         # full repo brief (cached)
bash .claude/tools/facts.sh          # toolchain + test commands
bash .claude/tools/preflight.sh      # env/secrets/toolchain check
bash .claude/tools/codemap.sh        # where things live, what's heavy
bash .claude/tools/untested.sh       # files with no test coverage
bash .claude/tools/dupes.sh          # duplicate code blocks
bash .claude/tools/quality.sh --with-tests   # full quality gate
bash .claude/tools/watch.sh --idle 60 -- make build  # safe build
bash .claude/tools/selfcheck.sh      # verify .claude/ config integrity
```

**CRITICAL — `watch.sh`:** wrap EVERY build, test, migration, or long-running command
in `watch.sh --idle 60 --`. Never let a command hang the session.

### Available agents from `.claude/agents/` (use via delegation, not by calling directly)

| Agent | When to use |
|-------|-------------|
| `devil` | Before any risky change (deploy, schema migration, key rotation, security cutover). Get BLOCK/PROCEED verdict first. |
| `architect` | Before designing a new system (e.g., `make preflight-production`, network segmentation). Gets contracts and interfaces right. |
| `security` | White-box attack review of any new auth/authz/crypto code. |
| `reviewer` | Pre-merge review of any P0/P1 change. |
| `builder` | TDD implementation — red→green→refactor. Use for all new code. |
| `forger` | Building new shell tools (e.g., `preflight-production.sh`). Knows the `tools/` conventions. |
| `norminette` | 42 C-norm / repo-norm compliance check. |

### Available skills from `.claude/skills/`

| Skill | When to use |
|-------|-------------|
| `debug` | When a verify gate fails unexpectedly. |
| `write-test` | Before fixing any P1+ bug — write the failing test first. |
| `api-endpoint` | Adding the Kong rate-limit plugin route entry. |
| `new-module` | `preflight-production.sh` as a new scripts/ops module. |
| `pr-review` | Full pre-merge quality audit before any P0 commit. |
| `incident` | If a security fix introduces a regression. |

---

## The work order — execute in this sequence

### Step 1: Wire the tools (15 min)

```bash
# Run selfcheck on the .claude/ config
bash .claude/tools/selfcheck.sh

# Brief yourself
bash .claude/tools/digest.sh
```

### Step 2: P0 verification (human required — report clearly)

Check whether the leaked GitHub PAT has been rotated. Check whether migration 065 ran
on all environments. Report the status. Do not proceed with P1 until P0 is confirmed.

```bash
# Check migration 065 status
docker exec mini-baas-postgres psql -U postgres -c \
  "SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname='public' LIMIT 20;"

# Confirm no plaintext __KONG_CORS_ORIGIN__ in rendered kong config
docker exec mini-baas-kong grep -c '__KONG_CORS_ORIGIN' /etc/kong/kong.yml \
  && echo "FAIL: placeholders not substituted" || echo "OK"
```

### Step 3: `make preflight-production` script (highest ROI item)

Use the `forger` agent and the `tools/` conventions to build
`scripts/ops/preflight-production.sh`. It must:

1. Check every security-critical env var from the table in §3.1 of the assessment
2. Check `POSTGRES_PASSWORD != 'postgres'`, `MONGO_INITDB_ROOT_PASSWORD != 'mongo'`
3. Check `SMTP_SECURE=true` if `SMTP_HOST != 'mailpit'`
4. Check no `__KONG_CORS_ORIGIN__` literal in `infra/docker/services/kong/conf/kong.yml`
5. Check `TENANT_HEADER_IDENTITY_HMAC=1`
6. Exit 0 with a green summary or exit 1 with a clear per-check failure message
7. Be wired into `make cloud-up` and `deploy/fly/boot.sh`

Standard: follows `.claude/tools/lib/common.sh` pattern.
Emit markdown. Support `--summary` and `--fix-hint` flags.

### Step 4: Invert the defaults (security posture shift)

The base `docker-compose.yml` and `config.env` should be production-safe. Dev
conveniences should be explicit opt-ins. Plan this change with the `architect` agent
before making it — it's a breaking change for dev workflows.

**Proposed:** create `config.dev.env` with all dev-permissive overrides. `make up`
loads it by default; `make cloud-up` does not.

### Step 5: P1 security items (work through the tracker)

For each item in `wiki/security/remediation-tracker-2025-07-14.md` still open
(📌, the "Open, tracked" section — the tracker has no 🔲 marker or P1 column):

1. Use `write-test` skill to write a failing test first
2. Use `builder` agent to implement the minimum fix
3. Run the quality gate
4. Run the relevant verify gate
5. Use `reviewer` agent for pre-merge review
6. Update the tracker to ✅

The four items this list used to start with are no longer open — per the tracker
(re-verified 2026-09-24):
- H-5 (ABAC default) — ➖ by design, awaiting a product decision; m139 asserts
  `API_KEY_ABAC_ENABLED` defaults off, and the bypass is now logged (H-5a, ✅).
- H-7 (Kong rate limit on key verify) — ⚪ mitigated: verify needs the service token;
  fast hash for new keys.
- H-15 (CORS pre-flight) — ✅ fixed in `abeeea71`; proof: m195 CORS preflight
  (prod-allowed `localhost:5180` → refused), phase 13 13/13.
- H-20 (ShellCheck SC2086) — ✅ fixed on `fix/sec-h20-quoting`; proof: the CI
  shellcheck step *Quoting (SC2086) on untrusted-input scripts* (red before, green after).

Pick the next item from the tracker's "Open, tracked" section.

### Step 6: CI consolidation

All quality gates must be in the main `ci.yml` and block merge. Current gaps:
- SonarCloud scan is a separate make target
- Security workflow is a separate file
- Trivy scan runs independently

Consolidate into a single `quality` job that gates the PR.

### Step 7: Load test baseline

Add a `bench-capacity` job to CI (`make bench-capacity`) that runs on `main` push,
writes artifacts to `artifacts/bench/`, and fails if median RPS drops more than 20%
below the m46 baseline. Every perf claim must cite an artifact.

---

## Rules for this agent specifically

1. **Run `preflight.sh` before any build.** If it fails, fix the environment first.
2. **Wrap every build in `watch.sh --idle 60 --`.** Never let a stuck process stall the session.
3. **Get a `devil` verdict before:** any schema migration, any auth/authz change, any
   deploy, any security flag cutover.
4. **Get a `reviewer` verdict before:** any P0 or P1 commit.
5. **Check `codemap.sh` and `dupes.sh` before writing new code.** Assume it already
   exists. If it does, use it. If it's duplicated, consolidate first.
6. **Every perf/capacity statement cites an artifact** (`artifacts/bench/…`) and the
   make target that reproduces it. No invented numbers.
7. **UNKNOWN = FAIL.** A finding without a command and its output is a hypothesis, not
   a fact. Never report a result you haven't verified.
8. **Report faithfully.** Failures stated, skips stated. A clean result is claimed only
   when verified.
9. **The minimalism ladder.** If a higher rung works, use it. No new abstraction for
   its own sake. `// ponytail:` on every deliberate shortcut.
10. **The vendor/AppFlowy problem.** 2880 tracked files with zero BaaS wiring. Before
    touching anything near `vendor/`, note this and recommend its removal/submoduling
    as a separate tracked task.

---

## Reference

| What | Where |
|------|-------|
| Project assessment (start here) | `wiki/security/project-assessment-2025-07-14.md` |
| Vulnerability report | `wiki/security/vulnerability-report-2025-07-14.md` |
| Remediation tracker | `wiki/security/remediation-tracker-2025-07-14.md` |
| ASVS control map | `wiki/security/security-audit-asvs.md` |
| Binding code rules | `.claude/rules/` |
| Agent roster | `.claude/AGENTS.md` |
| Tool index | `.claude/tools/README.md` |
| Hooks (enforcement layer) | `.claude/hooks/HOOKS-README.md` |
| Product roadmap | `wiki/product-plan/01-overview-and-sequencing.md` |
| GA checklist (human actions) | `HUMAN-ATOMS.md` |
| Service boundaries (binding) | `.claude/rules/service-boundaries.md` |
