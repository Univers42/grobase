# AGENTS.md — Plan mode

This file provides guidance to agents when working with code in this repository.

## Non-obvious architectural constraints

- **Three-plane seam is load-bearing:** Go control plane resolves API key → identity (`POST /v1/keys/verify`); Rust data plane executes + owner-scopes per request using that identity. TS query-router surfaces Rust's `EngineCapabilities`. Any work touching this seam must keep all three planes aligned.
- **TS→Rust cutover is per-request, not a build flag:** `RUST_DATA_PLANE_FORWARD=1` (TS-side, default OFF) is INDEPENDENT of `DATA_PLANE_ROUTER_PRODUCT_MODE` (`shadow`|`enabled`, Rust-side default `shadow`). Both halves must be tested independently.
- **Owner-scoping is per-request, not per-pool** — this is what lets `SHARE_POOLS` collapse 10K tenants onto one pool. Never add pool-level tenant context.
- **8 engine adapters must stay symmetrical** — a fix that works for Postgres but breaks the other 7 is not done.
- **All new behavior must be flag-gated OFF by default** — OFF is structural (Go routes not mounted unless `envBool("FLAG")` fires). A missing var = byte-parity with OSS edition.
- **Flag AND pattern:** features spanning Go + Rust/TS planes each need BOTH planes' flags truthy. Always identify both flag names when planning.
- **Migrations are forward-only** (forward-only, non-contiguous numbering — `ls scripts/migrations/postgresql` for the current set). Design features to never require rollback; gate the code first, migration follows.
- **Product shapes derive from cargo features**, not separate repos: `nano` (SQLite-only), `one` (+ auth/storage/admin), `default` (full `engines-full + control-pg + ratelimit-redis`). DynamoDB is opt-in, OFF by default.
- **Two compose-shaping dimensions:** EDITIONS (named plane sets) vs PACKAGES (customer tiers in `infra/config/packages/packages.json`). Precedence: `PROFILES` > `PACKAGE` > `EDITION`. `make up PACKAGE=nano` is invalid — use `make nano-up`.
- **`docker compose up` pulls prebuilt GHCR images** for every service marked `# pull-fallback` — plan for explicit `make build` steps when local source changes need to take effect.
- **Enterprise packages are commercially licensed** — the 12 Track-D packages under `src/control-plane/internal/{orgs,sso,scim,passkeys,ipguard,audit,compliance,erase,export,telemetryexport,trust,cmek}` each carry a `LICENSE` pointer. Moving code across the open-core line requires updating `LICENSING.md` and the directory `LICENSE`.
- **grobase is a generic contract factory** — zero app-specific code. Apps are declarative contracts at `infra/config/contracts/<app>.json`. Any plan that adds app-specific logic to grobase violates the service boundary.
- **WebSocket must go browser → the grobase server directly** — never plan Vercel WebSocket proxying.
- **Verify gates are the unit of "done"** — every feature needs a `scripts/verify/m<NN>-*.sh` gate. `ls scripts/verify` for the next free number. Plan gate numbering and include gate work in every milestone.
- **Go control plane: hexagonal architecture** — ports in domain packages, adapters implement ports, domain never imports infrastructure types. No `utils`/`shared`/`common` packages.
- **Shadow → parity → cutover → delete** for the TS→Rust migration — no legacy TS deletion unless m18 + shadow-parity + CI-forward all PASS. UNKNOWN = FAIL.
- **`claude-deal-with-the-devil` (external upstream repo, not vendored) as the `.claude/` reference:** its tools, hooks, agents, skills and rules are merged into `.claude/`; consult it for upstream changes before designing config from scratch. Its risk gate, quality bar and run-safely rules are now in `.claude/rules/` (`risk.md`, `quality-bar.md`, `run-safely.md`).
- **Subagent discipline (`.claude/AGENTS.md`):** fan-out only for genuinely independent slices (no shared write target), sequence dependency chains, always converge behind a quality gate. UNKNOWN = FAIL.
