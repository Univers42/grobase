# 05 — Orchestration, observability, DX & roadmap

> [00 Overview](00-overview.md) · [01 Gap analysis](01-gap-analysis.md) · [02 Layer & edition model](02-layer-edition-model.md) · [03 Control plane](03-control-plane.md) · [04 Data plane](04-data-plane.md) · **05 Orchestration & roadmap**

This doc covers the cross-cutting layers: the **Makefile orchestrator** (the operator's single control surface), cross-tier **observability**, **secrets/quality** gates, **SDK** completeness, **packaging**, and the **milestone roadmap**. Resolves **G1, G7, G9, G10, G11**.

---

## 1. The Makefile orchestrator (G1)

> Lives at `mini-baas-infra/Makefile`. The prior 641-line file is preserved at `mini-baas-infra/Makefile.legacy` for reference. **All Docker manipulation goes through `make` — never raw `docker compose`.**

### Design principle: one matrix, generated targets

The whole point is *no repetition*. Two maps are the single source of truth:

```make
# plane → compose profile(s)
PROFILES_data := data-plane
PROFILES_go   := go-control-plane
PROFILES_rust := rust-data-plane
# … one line per plane …

# edition → plane list
EDITION_query := data go rust adapter background
EDITION_prod  := data go rust adapter background storage realtime observability ops
EDITION_full  := $(PLANES)
```

From those, a `foreach`/`eval` loop **generates** the verbs so adding a plane or edition is a one-line change with no new recipes:

```make
define PLANE_RULES
up-$(1):   ; > $$(DC) $(addprefix --profile ,$(PROFILES_$(1))) up -d $$(SERVICE)
down-$(1): ; > $$(DC) $(addprefix --profile ,$(PROFILES_$(1))) stop
logs-$(1): ; > $$(DC) $(addprefix --profile ,$(PROFILES_$(1))) logs -f --tail=100
endef
$(foreach p,$(PLANES),$(eval $(call PLANE_RULES,$(p))))
```

> Implementation note: recipes use standard **TAB** indentation. (An earlier draft used `.RECIPEPREFIX := >`, but `>` on backslash-continuation lines is read by the shell as a redirect — `make -n` hides it because it never executes — so TABs are the robust choice.)

### Operator surface

```bash
# Editions (whole shapes)
make up                    # default EDITION (query)
make up EDITION=lean       # smallest viable BaaS
make up EDITION=prod       # flagship + storage + realtime + obs + backups
make down                  # stop the current edition
make re EDITION=full       # fclean + rebuild + up full

# Planes (change layers live, against a running core)
make up-analytics          # add the analytics plane
make down-analytics        # remove it
make logs-rust             # follow just the data plane
make planes / make editions# introspect the manifest

# Service-grained
make logs SERVICE=kong
make restart SERVICE=query-router

# Lifecycle / quality (kept from legacy, de-duplicated)
make build · pull · ps · health · doctor · bench-startup
make tests · test-phase3 · test-postgres
make migrate · migrate-all · migrate-status · seed-mongo
make secrets · secrets-validate · secrets-rotate · check-secrets
make vault-init · vault-status · vault-rotate
make nestjs-ci · rust-data-plane-check · go-control-plane-check
make verify-m18 · verify-all          # milestone gates
make parity OLD=ts NEW=rust ROUTES=…  # layer-swap gate (§4)
make cutover PLANE=tenant-control     # gated promotion (03 §2.1)
```

### Why this is the right DSA

- **O(1) lines per plane/edition** — the matrix expands; recipes don't multiply (verb × plane is generated, not written).
- **Single source of truth** — `make planes`/`editions` print the maps, so docs can't drift from behaviour.
- **Pattern rules** for the open-ended families: `up-%`, `logs-%`, `verify-%`, `nestjs-build-%`, `cutover-%`.
- **Composable** — `EDITION=` selects a profile set; `SERVICE=` narrows any verb; `PROFILES=` is an escape hatch for ad-hoc shapes.

---

## 2. Cross-tier observability (G7)

Today only the TypeScript plane is fully observable (pino logs, `/metrics`, `/health`, OTel bootstrap + Tempo/otel-collector configs). The Go and Rust planes expose `/health` only, and traces don't cross language borders.

| Tier | Add | How |
|---|---|---|
| Go (control) | `/metrics` | `promhttp` handler on the shared mux (`internal/shared/server.go`) — one place, all three daemons inherit it |
| Rust (data) | `/metrics` + span continuation | a `tower` metrics layer; expose existing `PoolStats{active,idle,waiting}`; read inbound `traceparent` |
| All | W3C trace propagation | query-router already starts spans; forward `traceparent` on every internal hop so one trace spans TS → Go → Rust |
| Grafana | "Three Planes" dashboard | request rate/latency/error per plane + pool saturation + outbox lag |

Prometheus scrape config (`config/prometheus/prometheus.yml`) gains the Go/Rust targets once they expose `/metrics`. Outcome: a single trace ID followed from Kong through the Rust pool, and one dashboard that shows all three languages.

---

## 3. Secrets & quality lifecycle

- **Secrets** — keep `make secrets*` (generate/validate/rotate/check). Add `GROUP=tenant-dsn` rotation ([03 §2.4](03-control-plane.md)) and a Vault-backed credential provider ([04 §4](04-data-plane.md)). Vault stays a `control-plane`-profile concern.
- **Security gates** — `scripts/security/run-security-scans.sh`, ZAP baseline, Trivy, gitleaks, semgrep already run; wire them into `make audit` and CI so an edition can't ship with a known critical.
- **WAF** — `make waf-test` proves SQLi/XSS are blocked at the edge; keep it in the smoke set.

---

## 4. Parity / contract harness as a reusable gate (G10)

`scripts/verify/parity-probe.sh` proved the adapter-registry + engine cutovers but is one-shot. Promote it to a parameterised gate:

```bash
make parity OLD=ts NEW=rust ROUTES=query   # replay a fixed corpus against both, diff, emit verdict
```

- Records a machine-readable verdict to `artifacts/parity/<plane>-<date>.json`.
- `make cutover PLANE=…` refuses to flip a product mode unless the latest verdict for that plane is green **and** CI is green — encoding the deletion-gate doctrine (`.claude/instructions.md`) as a tool, not a hope.
- Every future layer swap (a new engine, a new isolation strategy, a TS→Rust slice) calls the same gate.

---

## 5. SDK completeness (G9)

`@mini-baas/js` is "the product API." Close the surface so app code never touches gateway paths:

| Domain | State | Add |
|---|---|---|
| auth / rest / query / storage / analytics / realtime | ✅ | — |
| capability-typed `engine()` clients | ✅ | verify `.transaction()` is wired to Rust `/v1/transactions*` |
| **functions** | ❌ | `client.functions.deploy()/invoke()` → `functions-runtime` |
| **webhooks** | ❌ | `client.webhooks.subscribe()/list()/delete()` → webhook-dispatcher |
| **tenant bootstrap** | ❌ | `client.tenant.bootstrap()` → tenant-control `/v1/tenants/me/bootstrap` |
| **admin/migrate** | ❌ | `client.admin.migrate()` (service-role) → Rust `/v1/admin/migrate` |

Keep the codegen discipline: `sdk/scripts/codegen-engines.mjs` regenerates the capability catalog from the live `/v1/capabilities`, and `introspectEngines()` fails loudly on drift.

---

## 6. Packaging beyond Compose (G11)

When (and only when) a hosting target appears, promote the Make manifest to the YAML form ([02 §6](02-layer-edition-model.md)) and generate Helm values / Kustomize overlays from it, so an `edition` means the same thing on Compose and K8s. Don't build the compiler before there's a second consumer — Compose-first remains correct for now.

---

## 7. Roadmap — sequenced so each step is shippable & reversible

| Phase | Theme | Deliverables | Gate |
|---|---|---|---|
| **P0** | Orchestrator + manifest | new `Makefile` (planes/editions matrix), reconcile compose `profiles:` to the canonical map, `make planes/editions` | `make help`, boot each edition in CI |
| **P1** | Gateway + admin surface | Kong `/admin/v1/*` routes to Go+Rust, README correction | `make verify-m11`, `verify-m19` |
| **P2** | Provisioning brain | `provision-control` reconcile API, real `seedDefaultRole`, isolation hooks | integration: provisioned tenant passes ABAC `decide` |
| **P3** | Capability planner + isolation | `plan()` over capabilities, `IsolationStrategy` (schema-per-tenant) | `make rust-data-plane-check`, `verify-m18`, `parity` |
| **P4** | Cross-tier observability | `/metrics` on Go+Rust, `traceparent` propagation, Three-Planes dashboard | trace spans all 3 planes |
| **P5** | Control-plane cutover | parity+cutover automation, tenant-control + webhook-dispatcher → enabled | green `make parity` verdict per plane |
| **P6** | SDK + credential providers | functions/webhooks/tenant/transactions in SDK, Vault provider + DSN rotation | SDK type tests, rotation drill |
| **P7** | Packaging (optional) | manifest → Helm/Kustomize | edition parity Compose↔K8s |

Each phase is independently valuable and leaves the platform shippable — no big-bang rewrite, consistent with the slice doctrine the project already lives by.

### Delivered so far (2026-06)

Verified, additive slices already landed (no deletions, gates respected). The
table notes **static** (compile/unit) and **live** (running-stack) verification.

| Slice | What | Static verify | Live verify (stack up) |
|---|---|---|---|
| **P0** | Makefile orchestrator (`mini-baas-infra/Makefile`) — plane/edition matrix, generated verbs (TAB recipes) | `make planes/editions/help` | `make up`/`up-<plane>` recreate services ✓ |
| **P3** | Rust capability planner — `validate_operation` + 6 unit tests, wired into `execute_query` as a parity-safe 400 gate | `cargo test -p data-plane-core` (6/6), `make rust-data-plane-check` | redis batch 101 → **400 `unsupported_capability` max_batch_size=100**; batch 5 → passes gate (501 from adapter, not a false reject); `make verify-m18` **PASS** |
| **P4** | Go `/metrics` (dependency-free, all 3 daemons) + Prometheus `go-control-plane` scrape job | `make go-control-plane-check`, `go test ./internal/shared/...`, `gofmt` clean | `/metrics` serves `baas_*` on :3021/:3022/:3025; Prometheus targets all **`up`**; `make verify-m19` **PASS** |
| **P4** | Rust `/metrics` (dependency-free, axum middleware + live `PoolStats`) + `rust-data-plane` scrape job — **G7 metrics complete across all 3 planes** | `cargo test -p data-plane-server` (10/10, +2 metrics tests) | `:4011/metrics` serves `baas_*` incl. `baas_data_plane_pool_connections`; Prometheus target **`up`** |
| **P1** | Kong `/admin/v1` → `adapter-registry-go:3021` (was the dead `:3020`) + README architecture-status | kong.yml `strip_path` reasoning | `GET /admin/v1/databases` → **HTTP 200** from the Go service |
| **P2 (started)** | `seedDefaultRole` no-op stub → real, idempotent ABAC role seeding on tenant bootstrap (`internal/tenants`) — fallback to baseline `user`, never auto-escalates to `admin` | `make go-control-plane-check`, `gofmt` clean | bootstrap flips `has_permission` **false→true**; idempotent (no dup row); non-UUID owner skipped; `make verify-m19` **PASS** |
| **P2 (started)** | Idempotent `Bootstrap` — fixed the `Create`/`IssueKey` 23505-on-scan bug (shared `isUniqueViolation`), `findOrCreateBySlug` + key reuse; `+TestIsUniqueViolation` | `go vet`+`test`, `make verify-m19` **PASS** | re-bootstrap → `created:false, key_reuse:true`, **no 500**, exactly 1 key + 1 role |
| **P2 (core)** | **`POST /v1/provision` reconcile endpoint** — tenant + key + role + **mounts** (via adapter-registry HTTP) in one idempotent call (`provision.go`, `ADAPTER_REGISTRY_URL` env); status mapping unit tests | `go vet`+`test` (201/409/5xx), `make verify-m19` **PASS** | 1st → tenant+role+mount `created`; 2nd → `created:false, key_reuse:true`, mount `exists`; row confirmed in `tenant_databases` |
| **P3 (isolation)** | **`schema_per_tenant` enforcement** — `DatabaseMount.isolation` + sanitized `tenant_schema()`; Postgres `SET LOCAL search_path` after RLS (no-op for shared) | `cargo test -p data-plane-core` (10/10), `make verify-m18` **PASS** | same table/tenant/DSN → `schema_per_tenant` reads `tenant_acme.widgets`, shared reads `public.widgets` |
| **P2 (capstone)** | **provision↔query↔isolation connected** — mounts scoped by **slug** (fixes a reachability bug), provision creates `tenant_<slug>` via Rust `/v1/admin/migrate`; Go schema derivation pinned to Rust by shared test vector | `go vet`+`test` (incl. `TestTenantSchemaMatchesRust`), `make verify-m19` **PASS** | full chain: provision → schema created → mount `tenant_id=slug` → api-key `VerifyKey`=slug → `/connect` by slug → Rust reads the Go-created schema |
| **P3 (isolation persist+forward)** | adapter-registry **persists** `isolation` column + returns it from `/connect`; query-router proxy **forwards** it to the Rust mount (`AdapterResponse`→`RustProxyContext`→`mount.isolation`) | `go vet`+`test`, `make verify-m19` **PASS**; TS `tsc` clean | live: provision stores `schema_per_tenant`, `/connect` returns it, no-iso defaults `shared_rls`; forwarding deployed |
| **Gateway fix** | **query-router path bug** — `query.controller` `@Controller('query')` → `@Controller()` so the Kong `/query/v1` strip lands at root (matching `engines.controller`). + a `make build-svc-<service>` targeted-build target | `make verify-m11` trust checks **PASS** (compatible) | live: gateway query route **404 → 401** (routing fixed), `/query/v1/engines` → **200** |
| **Auth: api-key→envelope** | `ApiKeyMiddleware` now **mints a signed identity envelope** (`signIdentityEnvelope`, reuses the verifier's canonical+keys) so strict-mode `AuthGuard` accepts api-key callers; + **scope-based authorization** for api-key actors in `decidePermission` (admin/read/write), ABAC reserved for JWT users | `tsc` clean | **401 → 503 → 201** as each layer was fixed |
| **🎯 END-TO-END** | **the full product loop works live** | — | api-key → Kong → signed envelope → AuthGuard → scope auth → slug-scoped mount → isolation forwarded → Rust `search_path` → **reads `tenant_<slug>` row** (`HTTP 201`, `["TENANT-SCHEMA-ROW"]`, not the public row) |

**✅ The end-to-end product loop is now proven live (2026-06).** A real api-key
query — `POST /query/v1/<dbId>/tables/<table>` with `X-Baas-Api-Key` — returns
the **tenant-schema** row, exercising every layer in one HTTP call: Kong
key-auth → `ApiKeyMiddleware` verifies the key and **mints a signed envelope** →
strict `AuthGuard` accepts → **scope-based authorization** → mount resolved by
**slug** → **isolation forwarded** → Rust pins `search_path` to `tenant_<slug>`.
The returned row is from the tenant schema (not `public`), so isolation is
enforced through the gateway, not just at the engine.

**✅ Final peripherals delivered (2026-06).**
- **Gateway exposure of `/admin/v1/provision`** — a Kong service whose `url`
  carries `/v1/provision` + `strip_path` on the exact (more-specific-than
  `/admin/v1`) route forwards to tenant-control's `/v1/provision`. Live: **201**
  through Kong; **401** without the `X-Service-Token` (gate enforced).
- **Slug/UUID convention unified** — the tenant **slug** is canonical across the
  product surface (`VerifyKey`, provision mounts, query path); the UUID is the
  internal PK. `tenant-control.FindOne` now resolves by **either** (live: GET by
  slug and by uuid return the same tenant), and the convention is documented in
  `service.go`.
- **Cross-tier trace correlation (G7 tracing)** — the Rust router logs the
  inbound `traceparent` + `x-request-id` per request, and the query-router proxy
  forwards the correlation id. Live: Kong's request id appears in **both**
  query-router and Rust data-plane logs for one query. `m18`/`m19` still green.

**✅ TS adapter-registry retirement completed (2026-06).** The orphaned
`src/apps/adapter-registry/` (only `main.ts` remained, importing a deleted
`app.module`) was removed — completing the already-staged TS→Go cutover (the Go
`adapter-registry-go:3021` has served live all session; gates: live + parity +
`m19` green). Result: **monorepo `tsc` exit 0** and **`make verify-m11` fully
PASS** (its "TypeScript compiles" check was the only red, and it was red only on
this orphan).

Remaining (genuinely optional, future): full OTel span *continuation* in Rust
(today it logs the trace context for correlation — joining it as a child span
needs an OTel layer in the Rust router); broadening the `/admin/v1/*` gateway
surface beyond `provision`/`databases` to `tenants`/`keys`/`webhooks`; and the
deploy-target work (manifest → Helm/Kustomize, P7).

Still **runtime-gated / deferred** (per verify-before-change): tenant-control + webhook-dispatcher promotion out of `shadow` (needs `make parity`), the Rust `/metrics` + `traceparent` propagation, the broader `/admin/v1/{tenants,keys,webhooks}` routes (need path-rewrite design), and the last of the provisioning brain (P2): the reconcile endpoint (`/v1/provision`) now composes tenant + key + role + **mounts** idempotently — remaining is **isolation-strategy selection** (schema-/db-per-tenant, [04 §3](04-data-plane.md)) and **gateway exposure** of `/admin/v1/provision` (the shared path-rewrite item, since tenant-control uses a `/v1` prefix).

---

## 8. How I (Claude) help across this doc

- Author and validate the Makefile orchestrator (`make help`, dry-run `make -n up EDITION=full`) before anything depends on it — and use it as the only Docker entrypoint for the rest of the work.
- Add `/metrics` to the Go shared mux and a Rust metrics layer in small PRs, each verified green.
- Turn `parity-probe.sh` into the parameterised `make parity` gate and make `make cutover` depend on it.
- Extend the SDK domain-by-domain with type tests, keeping the codegen/drift discipline intact.
