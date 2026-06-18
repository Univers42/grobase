# scripts/

Operational scripts, **organized by family** — one concern per directory. Shared *sourced* helpers
live in `lib/`; everything else is grouped by what it does.

| Dir | What | Entry points |
|-----|------|--------------|
| `test/phase/`   | Numbered integration battery `phase1..16` (+ `postgres-mvp-flow.sh`); shares `test-ui.sh` | `make tests`, `make test-phase%`, `make test-postgres` |
| `test/smoke/`   | Standalone post-deploy liveness probes (not in the phase glob) | run directly |
| `test/postman/` | Newman/Postman collection runners | `make test-offers`, `make test-edge` |
| `verify/`       | Milestone gates `m<NN>-*.sh` (the unit of "done") + `run-gate-battery.sh`, `parity*.sh`, `_signed-fetch.mjs` | `make verify-%`, `make verify-all`, `make conformance` |
| `migrations/`   | SQL/JS schema migrations (`postgresql/ mongodb/ mysql/`) — **data, not executables** | `make migrate*` |
| `bench/`        | Performance/capacity/footprint harnesses; `bench/scale/` holds the 100K-tenant run + pooler doc | `make bench-*` |
| `report/`       | Zero-dep HTML report generators | `make reports`, `make master-report` |
| `security/`     | SAST/DAST/IaC/dependency scanners + compliance evidence | `make audit-deps`, `run-security-scans.sh` |
| `seed/`         | Tenant/demo data seeders (incl. `seed-live-demo.sh`, `seed-mongo.sh`) | `make seed-live-demo`, `make seed-mongo` |
| `secrets/`      | Secret lifecycle: generate / rotate-jwt / validate | `make secrets*` |
| `env/`          | Local `.env` + runtime-secret generation (`generate-env.sh` + bootstrap chain) | `make env` (auto-run by `make up`) |
| `vault/`        | Vault entrypoint, token recovery, session/env bridges | runtime + admin |
| `certs/`        | Local CA/cert generation + OS/browser trust helpers | `make certs` |
| `db/`           | Postgres/Mongo bootstrap, role/password sync, dev reset (`db-bootstrap.psql` is mounted by compose) | compose + helpers |
| `ci/`           | Local CI / validation / release gates (`run-ci-local`, `validate-all`, `preflight-check`, `check-secrets`, `pin-digests`, `install.sh`) | `make preflight`, `npm run ci:local` |
| `deploy/`       | Non-Compose packaging generation (`gen-deploy.py` → repo-root `deploy/`) | `make deploy-gen` |
| `ops/`          | Misc operational helpers: `resolve-ports.sh`, `openapi-collect.sh`, `sonar-fetch-issues.sh`, `replay-commits.sh` | various |
| `lib/`          | **Shared sourced helpers** — `service-auth.sh` (HMAC signer), `lib-live-tenant.sh` (live-secret discovery; sourced by ~22 gates + bench/seed), `lib-bench.sh`, `lib-workload.sh`, `lib-report.mjs` | `source`d only |

**Conventions**
- A script references siblings/libs **relative to its own location** (`${SCRIPT_DIR}/../lib/…`); the
  build layer (Makefile / CI / compose) references it by its **family path** (`scripts/<family>/…`).
- Family subdirs are kept exactly **one level** under `scripts/` so the cross-family `../lib/`,
  `../verify/` source paths resolve.
- Shell scripts follow [`.claude/rules/refactor-shell.md`](../.claude/rules/refactor-shell.md)
  (POSIX-leaning, `shellcheck -s sh` clean).
