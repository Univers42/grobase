# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile  (layer/edition orchestrator)            :+:      :+:    :+:     #
#                                                     +:+ +:+         +:+       #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+          #
#                                                 +#+#+#+#+#+   +#+             #
#    mini-baas — one control surface for a swappable-layer BaaS                #
#    The previous 641-line file is preserved as Makefile.legacy.               #
#    Anything not defined here is reachable via:  make legacy-<target>         #
#                                                                              #
# **************************************************************************** #

SHELL          := /bin/bash
.SHELLFLAGS    := -ec
.DEFAULT_GOAL  := help

# --------------------------------------------------------------------------- #
#  Variables                                                                   #
# --------------------------------------------------------------------------- #
PROJECT        := mini-baas
COMPOSE_FILE   ?= docker-compose.yml
IMAGE_TAG      ?= latest
REGISTRY       ?= localhost:5000
SERVICE        ?=
STEPS          ?= 1
HOOKS_DIR      := vendor/scripts/hooks
DC             := docker compose -f $(COMPOSE_FILE)

# Colors
_B := \033[0;34m
_G := \033[0;32m
_Y := \033[1;33m
_R := \033[0;31m
_C := \033[0;36m
_W := \033[1m
_D := \033[2m
_0 := \033[0m

# ========================================================================== #
#  THE MANIFEST — single source of truth (see wiki/02-layer-edition-model.md) #
# ========================================================================== #
# A PLANE is a capability slice mapped to compose profile(s).
# An EDITION is a named, validated set of planes ("a known-good shape").
# Every up-/down-/logs- target below is GENERATED from these two maps, so
# adding a plane or an edition is a one-line change — never a new recipe.

PLANES := data control go rust adapter background analytics storage realtime \
          functions observability ops studio playground engines

# plane -> compose profile(s)
PROFILES_data          := data-plane
PROFILES_control       := control-plane
PROFILES_go            := go-control-plane
PROFILES_rust          := rust-data-plane
PROFILES_adapter       := adapter-plane
PROFILES_background    := background
PROFILES_analytics     := analytics
PROFILES_storage       := storage
PROFILES_realtime      := realtime
PROFILES_functions     := functions
PROFILES_observability := observability
PROFILES_ops           := ops backups
PROFILES_studio        := studio
PROFILES_playground    := playground
# Extra database engines (mariadb/cockroachdb/mssql) — the à-la-carte "extra
# engines" add-on / Max package. Optional; never in default editions.
PROFILES_engines       := engines-extra

EDITIONS := lean query realtime analytics prod full

# edition -> plane list  (core, profile-less, is always included)
EDITION_lean      :=
EDITION_query     := data go rust adapter background
EDITION_realtime  := data go rust adapter background realtime storage
EDITION_analytics := data storage analytics
EDITION_prod      := data go rust adapter background storage realtime observability ops
# `playground` is a demo UI whose static assets are NOT checked into this repo, so its
# bind-mount (./playground) has nothing to serve. Excluded from `full` so `make up
# EDITION=full` comes up clean; restore the playground/ assets + drop the filter to re-enable.
EDITION_full      := $(filter-out playground,$(PLANES))

# Which edition `make up` / `make down` operate on by default.
EDITION ?= query

# A PACKAGE is the customer-facing service tier (Phase 4 — mirrors
# config/packages/packages.json): like an EDITION but named for the product
# catalog. ADDONS appends à-la-carte planes (realtime/analytics/engines/…).
# `make up PACKAGE=pro ADDONS="analytics engines"` resolves to compose profiles
# exactly like EDITION. Precedence: PROFILES > PACKAGE > EDITION.
PACKAGES := basic essential pro max
# basic = the Pi-class lean tier: SQLite-first, served Node-free via the Rust
# /data/v1 bypass — only the always-on core + Go control + Rust data plane.
PACKAGE_basic     := go rust
# essential = pg/sqlite OLTP + Node orchestration, NO mongo/mysql containers:
# the `data` plane joins at pro. outbox-relay tolerates the missing mongo
# (MONGO_OPTIONAL) and the tier's capability mask already forbids mongo mounts.
PACKAGE_essential := go rust adapter background
PACKAGE_pro       := $(PACKAGE_essential) data storage realtime
PACKAGE_max       := $(PACKAGE_pro) analytics observability functions engines
ADDONS ?=

# Functions: plane-list -> sorted profiles -> `--profile x --profile y`
profiles_of = $(sort $(foreach p,$(1),$(PROFILES_$(p))))
flags_of    = $(addprefix --profile ,$(call profiles_of,$(1)))

# Active profiles for the generic edition-driven verbs. Precedence:
#   PROFILES= (raw profiles) > PACKAGE= (+ADDONS, the product tier) > EDITION=.
#   make up PROFILES="data-plane storage"     # ad-hoc raw profiles
#   make up PACKAGE=pro ADDONS="analytics"    # a product tier + add-on
#   make up EDITION=realtime                  # a known-good edition
ifdef PROFILES
ACTIVE_PROFILES := $(PROFILES)
else ifdef PACKAGE
ACTIVE_PROFILES := $(call profiles_of,$(PACKAGE_$(PACKAGE)) $(ADDONS))
else
ACTIVE_PROFILES := $(call profiles_of,$(EDITION_$(EDITION)))
endif
PROFILE_FLAGS := $(addprefix --profile ,$(ACTIVE_PROFILES))
DCE           := $(DC) $(PROFILE_FLAGS)

# --------------------------------------------------------------------------- #
#  Internal prerequisites (no ## = hidden from help)                           #
# --------------------------------------------------------------------------- #
_require-docker:
	@command -v docker >/dev/null 2>&1 || { echo >&2 "Docker is not installed."; exit 1; }

_require-compose: _require-docker
	@docker compose version >/dev/null 2>&1 || { echo >&2 "Docker Compose v2 plugin is required."; exit 1; }

_rm-stale:
	@ids=$$(docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' | awk '/ mini-baas-/ && ($$3=="Created"||$$3=="Exited") {print $$1}'); \
	[ -z "$$ids" ] || { echo -e "$(_Y)Removing stale containers…$(_0)"; docker rm -f $$ids >/dev/null; }

# ========================================================================== #
##@ 42 Classics
# ========================================================================== #
all: ## Build images & start the default EDITION
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory up

all-full: ## Build & start the FULL edition
	@$(MAKE) --no-print-directory EDITION=full all

clean: down ## Stop the current edition (alias for down)

fclean: _require-compose ## Destructive: stop everything, prune containers/volumes/images/cache
	@echo -e "$(_Y)$(_W)Running destructive Docker cleanup…$(_0)"
	@$(DC) $(call flags_of,$(PLANES)) down --volumes --remove-orphans 2>/dev/null || true
	@ids=$$(docker ps -aq); [ -z "$$ids" ] || docker rm -f $$ids >/dev/null 2>&1 || true
	@docker system prune -af --volumes >/dev/null 2>&1 || true
	@docker builder prune -af >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ Full Docker clean complete$(_0)"

re: ## Full reset: fclean then rebuild & start (honours EDITION)
	@$(MAKE) --no-print-directory fclean
	@$(MAKE) --no-print-directory all

# ========================================================================== #
##@ Stack (edition-driven — set EDITION=lean|query|realtime|analytics|prod|full)
# ========================================================================== #
up: _require-compose _rm-stale ## Start the selected EDITION (detached)
	@echo -e "$(_B)Starting edition '$(_W)$(EDITION)$(_0)$(_B)' → profiles: $(_C)$(ACTIVE_PROFILES)$(_0)"
	@eval "$$(bash scripts/resolve-ports.sh 2>/dev/null || true)"; $(DCE) up -d $(SERVICE)
	@echo -e "$(_G)✓ Up$(_0)"

down: _require-compose ## Stop & remove the selected EDITION
	@$(DCE) down
	@echo -e "$(_G)✓ Down$(_0)"

restart: _require-compose ## Restart (SERVICE=<name> to target one)
	@$(DCE) restart $(SERVICE)
	@echo -e "$(_G)✓ Restarted$(_0)"

ps: _require-compose ## Show service status for the selected EDITION
	@$(DCE) ps

logs: _require-compose ## Follow logs (SERVICE=<name> to filter)
	@$(DCE) logs -f --tail=100 $(SERVICE)

pull: _require-compose ## Pull images for the selected EDITION
	@$(DCE) pull
	@echo -e "$(_G)✓ Pulled$(_0)"

build: _require-compose ## Build images for the selected EDITION (BuildKit, parallel)
	@DOCKER_BUILDKIT=1 $(DCE) build --build-arg BUILDKIT_INLINE_CACHE=1
	@echo -e "$(_G)✓ Build complete$(_0)"

build-svc-%: _require-compose ## Build ONE service image (all profiles defined, builds only $*; e.g. make build-svc-query-router)
	@DOCKER_BUILDKIT=1 $(DC) $(call flags_of,$(PLANES)) build $*
	@echo -e "$(_G)✓ built $*$(_0)"

health: ## Quick gateway health probe
	@echo -e "$(_B)Checking endpoints…$(_0)"
	@curl -fsS http://localhost:8000/auth/v1/health >/dev/null && echo "  ✓ /auth/v1/health" || echo "  ✗ /auth/v1/health"
	@curl -fsS http://localhost:8000/rest/v1/ >/dev/null && echo "  ✓ /rest/v1/" || echo "  ✗ /rest/v1/"

bench-startup: _require-compose _rm-stale ## Time the stack until health checks pass (target ≤90s)
	@t0=$$(date +%s); eval "$$(bash scripts/resolve-ports.sh 2>/dev/null || true)"; $(DCE) up -d; \
	for svc in mini-baas-postgres mini-baas-gotrue mini-baas-postgrest mini-baas-kong; do \
		printf "  Waiting: %-26s" "$$svc"; \
		timeout 120 sh -c "while [ \"$$(docker inspect --format='{{.State.Health.Status}}' $$svc 2>/dev/null)\" != 'healthy' ]; do sleep 1; done" 2>/dev/null \
			&& echo -e "$(_G)✓$(_0)" || echo -e "$(_R)✗ (timeout)$(_0)"; \
	done; \
	t1=$$(date +%s); el=$$((t1-t0)); \
	[ "$$el" -le 90 ] && echo -e "$(_G)$(_W)✓ healthy in $${el}s$(_0)" || echo -e "$(_R)$(_W)✗ $${el}s (>90s)$(_0)"

bench-footprint: _require-compose ## Measure RAM/CPU/disk of the active PACKAGE/EDITION/PROFILES (BAR_MB= asserts a budget)
	@PROFILES="$(ACTIVE_PROFILES)" \
		LABEL="$(if $(PROFILES),custom,$(if $(PACKAGE),$(PACKAGE),$(EDITION)))" \
		BAR_MB="$(BAR_MB)" bash scripts/bench/footprint.sh

bench-load: _require-compose ## Sustained-load bench, Kong→/data/v1 (PACKAGE= WORKLOAD=crud|aggregate|batch MODE=short|full RATE=)
	@PACKAGE="$(if $(PACKAGE),$(PACKAGE),essential)" WORKLOAD="$(if $(WORKLOAD),$(WORKLOAD),crud)" \
		MODE="$(if $(MODE),$(MODE),short)" RATE="$(RATE)" bash scripts/bench/load.sh

bench-capacity: _require-compose ## Ramp to the latency/error wall — true plane capacity (PACKAGE=)
	@PACKAGE="$(if $(PACKAGE),$(PACKAGE),essential)" bash scripts/bench/capacity.sh

bench-mem: _require-compose ## RSS under sustained load: peak + drift slope (PACKAGE= DURATION=30m RATE=)
	@PACKAGE="$(if $(PACKAGE),$(PACKAGE),essential)" DURATION="$(if $(DURATION),$(DURATION),30m)" \
		RATE="$(RATE)" bash scripts/bench/mem-under-load.sh

bench-compare: ## Competitive graph report from scripts/bench/compare-data.json → artifacts/bench/compare/ (zero-dep SVG, no host node) (DATA= OUT=)
	@mkdir -p artifacts/bench/compare
	@docker run --rm -u "$(shell id -u):$(shell id -g)" \
		-v "$(CURDIR)/scripts/bench":/b \
		-v "$(CURDIR)/artifacts":/b/artifacts \
		-w /b public.ecr.aws/docker/library/node:22-bookworm \
		node compare-report.mjs \
			--data "$(if $(DATA),$(DATA),/b/compare-data.json)" \
			--out "$(if $(OUT),$(OUT),/b/artifacts/bench/compare)"
	@echo -e "$(_G)$(_W)✓ compare report → artifacts/bench/compare/{index.html,report.md,charts/}$(_0)"

master-report: ## ONE detailed HTML comparison report (perf + offers + matrix + edge) → wiki/reports/comparison-report.html (zero-dep, no host node)
	@docker run --rm -u "$(shell id -u):$(shell id -g)" \
		-v "$(CURDIR)/..":/b -w /b public.ecr.aws/docker/library/node:22-bookworm \
		node /b/mini-baas-infra/scripts/report/master-report.mjs \
			--infra /b/mini-baas-infra --out /b/wiki/reports/comparison-report.html
	@echo -e "$(_G)$(_W)✓ comparison report → wiki/reports/comparison-report.html$(_0)"

# All HTML reports flow through ONE design system (scripts/report/lib-report.mjs):
# styled, graphics-rich (inline SVG), zero-dep, CSP-safe. `make reports` regenerates
# the whole wiki/reports/ suite + the portal index — the reproducible single command.
# arg-less generators (each resolves its own data/out paths from import.meta.url)
REPORT_GENS := supabase-verdict-report security-wins-report network-controls-report compliance-posture-report edge-reliability-report benchmark-resources-report allmetrics-verdict-report
reports: master-report ## Regenerate EVERY HTML report (comparison + supabase-verdict + security/network/compliance wins) + portal (zero-dep, no host node)
	@for g in $(REPORT_GENS); do \
		echo "  → $$g"; \
		docker run --rm -u "$(shell id -u):$(shell id -g)" \
			-v "$(CURDIR)/..":/b -w /b public.ecr.aws/docker/library/node:22-bookworm \
			node /b/mini-baas-infra/scripts/report/$$g.mjs || exit 1; \
	done
	@docker run --rm -u "$(shell id -u):$(shell id -g)" \
		-v "$(CURDIR)/..":/b -w /b public.ecr.aws/docker/library/node:22-bookworm \
		node /b/mini-baas-infra/scripts/report/portal.mjs \
			--data /b/mini-baas-infra/scripts/bench/offers-compare-data.json \
			--out /b/wiki/reports/index.html \
			--bench3 benchmark-3way.html --bench9 benchmark-9way.html --postman postman-offers-report.html
	@echo -e "$(_G)$(_W)✓ all HTML reports + portal → wiki/reports/ (open wiki/reports/index.html)$(_0)"

scale-seed: _require-compose ## Provision SCALE= bench tenants (+keys+mounts) → artifacts/scale/tenants-<N>.jsonl (MOUNTS= ISOLATION= CONCURRENCY=)
	@SCALE="$(if $(SCALE),$(SCALE),1000)"; \
	TC_PORT="$$(docker port mini-baas-tenant-control 3022/tcp 2>/dev/null | head -1 | sed 's/.*://')"; \
	[ -n "$$TC_PORT" ] || { echo "tenant-control not up (make up PACKAGE=… first)"; exit 1; }; \
	TOKEN="$$(docker inspect mini-baas-tenant-control --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^INTERNAL_SERVICE_TOKEN=//p' | head -1)"; \
	TMODE="$$(docker inspect mini-baas-tenant-control --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^SERVICE_TOKEN_MODE=//p' | head -1)"; \
	PG_USER="$$(docker inspect mini-baas-postgres --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_USER=//p' | head -1)"; \
	PG_PASS="$$(docker inspect mini-baas-postgres --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)"; \
	PG_DB="$$(docker inspect mini-baas-postgres --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_DB=//p' | head -1)"; \
	mkdir -p artifacts/scale; \
	docker run --rm --network host -v "$(CURDIR)/go/control-plane":/src -v "$(CURDIR)/artifacts":/artifacts -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
		-e SERVICE_TOKEN_MODE="$$TMODE" golang:1.25-bookworm \
		go run ./cmd/scale-seed -n "$$SCALE" -base "http://127.0.0.1:$$TC_PORT" -token "$$TOKEN" \
		-dsn "postgres://$${PG_USER:-postgres}:$${PG_PASS:-postgres}@postgres:5432/$${PG_DB:-postgres}" \
		-mounts "$(if $(MOUNTS),$(MOUNTS),1)" -isolation "$(if $(ISOLATION),$(ISOLATION),shared_rls)" \
		-plan "$(if $(PLAN),$(PLAN),pro)" \
		-prefix "$(if $(PREFIX),$(PREFIX),scale)" \
		-concurrency "$(if $(CONCURRENCY),$(CONCURRENCY),16)" $(if $(RESUME),-resume,) \
		-out "/artifacts/scale/tenants-$$SCALE.jsonl"; \
	docker run --rm -v "$(CURDIR)/artifacts":/a alpine:3.21 chown -R $(shell id -u):$(shell id -g) /a/scale

scale-teardown: _require-compose ## Soft-delete every tenant in artifacts/scale/tenants-<SCALE>.jsonl
	@SCALE="$(if $(SCALE),$(SCALE),1000)"; \
	TC_PORT="$$(docker port mini-baas-tenant-control 3022/tcp 2>/dev/null | head -1 | sed 's/.*://')"; \
	TOKEN="$$(docker inspect mini-baas-tenant-control --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^INTERNAL_SERVICE_TOKEN=//p' | head -1)"; \
	TMODE="$$(docker inspect mini-baas-tenant-control --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^SERVICE_TOKEN_MODE=//p' | head -1)"; \
	docker run --rm --network host -v "$(CURDIR)/go/control-plane":/src -v "$(CURDIR)/artifacts":/artifacts -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
		-e SERVICE_TOKEN_MODE="$$TMODE" golang:1.25-bookworm \
		go run ./cmd/scale-seed -teardown -base "http://127.0.0.1:$$TC_PORT" -token "$$TOKEN" \
		-out "/artifacts/scale/tenants-$$SCALE.jsonl"

audit-deps: ## Supply-chain CVE scan — cargo-audit (Rust) + govulncheck (Go)
	@bash scripts/security/audit-deps.sh

# ========================================================================== #
##@ Planes (change layers live — up-<plane> / down-<plane> / logs-<plane>)
# ========================================================================== #
# These targets are GENERATED from $(PLANES). One eval loop → every verb for
# every plane, with zero repeated recipes. Run `make planes` to list them.
define PLANE_RULES
up-$(1): _require-compose ## (generated) start the '$(1)' plane on a running core
	@echo -e "$(_B)+ plane $(_W)$(1)$(_0) → $(_C)$(PROFILES_$(1))$(_0)"
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) up -d $$(SERVICE)

down-$(1): _require-compose ## (generated) stop the '$(1)' plane
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) stop $$(SERVICE)

restart-$(1): _require-compose ## (generated) restart the '$(1)' plane
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) restart $$(SERVICE)

logs-$(1): _require-compose ## (generated) follow the '$(1)' plane logs
	@$(DC) $(addprefix --profile ,$(PROFILES_$(1))) logs -f --tail=100 $$(SERVICE)
endef
$(foreach p,$(PLANES),$(eval $(call PLANE_RULES,$(p))))

observe: up-observability ## Alias: start the observability plane
	@echo -e "  Grafana: http://localhost:3030   Prometheus: http://localhost:9090"

planes: ## List planes and the profiles they activate
	@echo -e "$(_W)$(_C)Planes$(_0)  (use: make up-<plane> / down-<plane> / logs-<plane>)"
	@$(foreach p,$(PLANES),printf "  $(_G)%-14s$(_0) $(_D)%s$(_0)\n" "$(p)" "$(PROFILES_$(p))";)

editions: ## List editions and the planes they include
	@echo -e "$(_W)$(_C)Editions$(_0)  (use: make up EDITION=<name>)"
	@$(foreach e,$(EDITIONS),printf "  $(_G)%-10s$(_0) $(_D)%s$(_0)\n" "$(e)" "$(if $(EDITION_$(e)),$(EDITION_$(e)),core only)";)

packages: ## List service-tier packages and the planes they include (Phase 4)
	@echo -e "$(_W)$(_C)Packages$(_0)  (use: make up PACKAGE=<tier> ADDONS=\"<plane>…\")"
	@$(foreach p,$(PACKAGES),printf "  $(_G)%-10s$(_0) $(_D)%s$(_0)\n" "$(p)" "$(PACKAGE_$(p))";)
	@echo -e "  $(_D)source of truth: config/packages/packages.json (capability masks + limits + engines)$(_0)"

doctor: ## Environment sanity check
	@echo -e "$(_B)Doctor$(_0)"
	@command -v docker >/dev/null 2>&1 && echo "  ✓ docker" || echo "  ✗ docker"
	@docker compose version >/dev/null 2>&1 && echo "  ✓ compose v2" || echo "  ✗ compose v2"
	@[ -f .env ] && echo "  ✓ .env present" || echo "  • .env missing (run: make env)"
	@echo "  • EDITION=$(EDITION) → profiles: $(ACTIVE_PROFILES)"

# ========================================================================== #
##@ Tests & verification
# ========================================================================== #
tests: ## Run all phase smoke tests (phase1→N)
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	export PUBLIC_APIKEY=$${PUBLIC_APIKEY:-$$APIKEY}; \
	export SERVICE_ROLE_KEY=$${SERVICE_ROLE_KEY:-$$(grep '^SERVICE_ROLE_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	rc=0; for s in $$(ls -1 ./scripts/phase*-*.sh ./scripts/phase*-*.py 2>/dev/null | sort -t/ -k3 -V); do \
		case "$$s" in *.py) FORCE_COLORS=1 python3 "$$s" ;; *) FORCE_COLORS=1 bash "$$s" ;; esac || rc=1; sleep 1; \
	done; exit $$rc

test-phase%: ## Run one phase (e.g. make test-phase3)
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	s=$$(ls scripts/phase$*-*.sh scripts/phase$*-*.py 2>/dev/null | head -1); \
	[ -n "$$s" ] || { echo -e "$(_R)No test for phase $*$(_0)"; exit 1; }; \
	case "$$s" in *.py) FORCE_COLORS=1 python3 "$$s" ;; *) FORCE_COLORS=1 bash "$$s" ;; esac

test-postgres: ## Run the PostgreSQL MVP happy-path flow
	@FORCE_COLORS=1 bash ./scripts/postgres-mvp-flow.sh

test-offers: ## Postman/newman offer-capability proof vs the LIVE stack → artifacts/test/postman-offers-report.html (NEWMAN_IMAGE=)
	@bash scripts/test/run-postman.sh

test-edge: ## Data-driven edge corpus (1500+ vectors, one newman iteration each) vs the LIVE data plane → artifacts/test/edge-report.html
	@bash scripts/test/run-edge-postman.sh

verify-%: ## Run a milestone gate (e.g. make verify-m18)
	@s=$$(ls scripts/verify/$*-*.sh 2>/dev/null | head -1); \
	[ -n "$$s" ] || { echo -e "$(_R)No verify gate '$*'$(_0)"; exit 1; }; \
	bash "$$s"

verify-all: ## Run every milestone gate (m1…m19)
	@rc=0; for s in $$(ls scripts/verify/m*-*.sh | sort -V); do \
		echo -e "$(_B)→ $$s$(_0)"; bash "$$s" || rc=1; done; exit $$rc

parity: ## Layer-swap parity gate (NEW=<url> [OLD=<url>] [ROUTES=<set>] [RECORD=1]) — emits a verdict
	@OLD="$(OLD)" NEW="$(NEW)" ROUTES="$(ROUTES)" bash scripts/verify/parity.sh $(if $(RECORD),--record,)

parity-suite: ## Legacy full-suite TS↔Rust shadow probe (restarts query-router; historical)
	@bash scripts/verify/parity-probe.sh

cutover-%: ## Gated promotion of a plane/service (runs parity, then restarts it) — override NEW=/ROUTES= per plane
	@echo -e "$(_Y)Cutover '$*' — requires a green parity verdict first.$(_0)"
	@$(MAKE) --no-print-directory parity NEW="$(or $(NEW),http://127.0.0.1:4011)" ROUTES="$(or $(ROUTES),data-plane-contract)"
	@$(DCE) up -d --no-deps $* && echo -e "$(_G)✓ '$*' restarted; set its *_PRODUCT_MODE=enabled in .env to make it live$(_0)"

deploy-gen: ## (G11) Compile the edition manifest → Helm values + Kustomize overlays (DEPLOY_REGISTRY=/DEPLOY_TAG= override images)
	@command -v python3 >/dev/null 2>&1 || { echo -e "$(_R)python3 required$(_0)"; exit 1; }
	@python3 scripts/gen-deploy.py

deploy-template: ## (G11) Render an edition's K8s manifests via Helm (EDITION=lean|query|realtime|analytics|prod|full)
	@command -v helm >/dev/null 2>&1 || { echo -e "$(_R)helm required$(_0)"; exit 1; }
	@helm template mini-baas deploy/helm/mini-baas -f deploy/helm/mini-baas/values-$(EDITION).yaml

waf-test: ## Confirm the WAF blocks SQLi/XSS at the edge
	@for q in "?id=1%20OR%201=1" "/<script>alert(1)</script>"; do \
		code=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost/rest/v1/$$q"); \
		[ "$$code" = "403" ] && echo "  ✓ blocked ($$q)" || echo "  ✗ expected 403, got $$code ($$q)"; \
	done

# ========================================================================== #
##@ Migrations & data
# ========================================================================== #
migrate: ## Apply pending PostgreSQL migrations
	@set -e; for f in $$(ls -1 scripts/migrations/postgresql/*.sql 2>/dev/null | sort); do \
		echo "  Applying: $$f"; sed '/^#/d' "$$f" | $(DC) exec -T postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f -; \
	done; echo -e "$(_G)✓ PostgreSQL migrations applied$(_0)"

migrate-mongo: ## Apply MongoDB migrations
	@for f in $$(ls -1 scripts/migrations/mongodb/*.js 2>/dev/null | sort); do \
		echo "  Applying: $$f"; $(DC) --profile data-plane exec -T mongo mongosh mini_baas < "$$f"; done
	@echo -e "$(_G)✓ MongoDB migrations applied$(_0)"

migrate-mysql: ## Apply MySQL migrations
	@set -e; for f in $$(ls -1 scripts/migrations/mysql/*.sql 2>/dev/null | sort); do \
		echo "  Applying: $$f"; $(DC) --profile data-plane exec -T mysql sh -ec 'mysql -u"$${MYSQL_USER:-mini_baas}" -p"$${MYSQL_PASSWORD:-mini_baas_pw}" "$${MYSQL_DATABASE:-mini_baas}"' < "$$f"; done
	@echo -e "$(_G)✓ MySQL migrations applied$(_0)"

migrate-all: migrate migrate-mongo migrate-mysql ## Apply PG + Mongo + MySQL migrations

migrate-status: ## Show applied migration versions
	@$(DC) exec -T postgres psql -U postgres -d postgres -c "SELECT version, name, applied_at FROM schema_migrations ORDER BY version;" 2>/dev/null || echo "  No migrations table yet — run make migrate."

seed-mongo: _require-compose ## Seed MongoDB demo data
	@bash scripts/seed-mongo.sh

seed-live-demo: _require-compose ## Seed the live-database demo across pg+mysql+mongo (owned by the osionos app key; RESEED=1 wipes first)
	@bash scripts/seed-live-demo.sh

# ========================================================================== #
##@ Secrets & Vault
# ========================================================================== #
secrets: ## Generate all secrets → .env
	@bash scripts/secrets/generate-secrets.sh
secrets-validate: ## Validate required secrets exist
	@bash scripts/secrets/validate-secrets.sh
secrets-rotate: ## Rotate JWT secret (GROUP=jwt|tenant-dsn|all)
	@bash scripts/secrets/rotate-jwt.sh
check-secrets: ## Scan source for hardcoded secrets
	@bash scripts/check-secrets.sh
env: ## Generate .env from template
	@bash scripts/generate-env.sh
vault-init: _require-compose ## Run Vault init/unseal/seed
	@$(DC) --profile control-plane run --rm vault-init
vault-status: _require-compose ## Check Vault seal status
	@docker exec mini-baas-vault vault status -address=http://127.0.0.1:8200 2>/dev/null || echo -e "$(_R)Vault not running$(_0)"
vault-rotate: _require-compose ## Rotate Vault secrets (GROUP=jwt|postgres|mongo|minio|kong|all)
	@docker exec mini-baas-vault /vault/scripts/rotate-secrets.sh $${GROUP:-all}

# ========================================================================== #
##@ Language tiers (TypeScript / Rust / Go)
# ========================================================================== #
# Node also runs INSIDE Docker (no node/npm on the host); node_modules lives
# in a named volume so the host tree stays clean and installs stay warm.
NODE_IMAGE := public.ecr.aws/docker/library/node:20-alpine
NODE_RUN    = docker run --rm -v "$(CURDIR)/src":/app -w /app \
	-v mini-baas-src-node-modules:/app/node_modules \
	-v mini-baas-npm-cache:/root/.npm \
	$(NODE_IMAGE)

nestjs-ci: ## TS: install + typecheck + lint + test (in Docker)
	@$(NODE_RUN) sh -c 'npm ci --ignore-scripts --prefer-offline --no-audit --no-fund \
		&& npx tsc --noEmit && npx eslint "apps/**/*.ts" "libs/**/*.ts" && npx jest --passWithNoTests'
nestjs-build-%: ## TS: build one app in Docker (e.g. make nestjs-build-query-router)
	@$(NODE_RUN) sh -c '[ -x node_modules/.bin/nest ] || npm ci --ignore-scripts --prefer-offline --no-audit --no-fund; npx nest build $*'
# Cargo runs INSIDE Docker (no rustc/cargo on the host). The registry and the
# per-workspace target dirs live in named volumes, so dependency downloads and
# incremental build state persist across runs while the host stays clean.
RUST_IMAGE          := public.ecr.aws/docker/library/rust:1.89-slim-bookworm
RUST_TOOLCHAIN_IMG  := mini-baas-rust-toolchain
CARGO_VOLS           = -v mini-baas-cargo-registry:/usr/local/cargo/registry -v mini-baas-cargo-git:/usr/local/cargo/git
CARGO_DPR            = docker run --rm -v "$(CURDIR)/docker/services/data-plane-router":/work -w /work $(CARGO_VOLS) -v mini-baas-dpr-target:/work/target $(RUST_TOOLCHAIN_IMG)
CARGO_REALTIME       = docker run --rm -v "$(CURDIR)/docker/services/realtime/realtime-agnostic":/work -w /work $(CARGO_VOLS) -v mini-baas-realtime-target:/work/target $(RUST_TOOLCHAIN_IMG)

_rust-toolchain: ## (internal) cargo-in-docker image: rust + pkg-config/libssl (layer-cached)
	@printf 'FROM $(RUST_IMAGE)\nRUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*\n' \
		| docker build -q -t $(RUST_TOOLCHAIN_IMG) - >/dev/null

rust-data-plane-check: _rust-toolchain ## Rust: cargo check the data-plane workspace (in Docker)
	@$(CARGO_DPR) cargo check --workspace

# Engine conformance: run the reusable battery (crates/engine-conformance)
# against ONE live engine over the mini-baas network. DSN is discovered from
# the running engine container (env + in-network alias), so a wrong host env
# can't poison it. New engines (Phase 3) only merge once `conformance-<engine>`
# is green. `make conformance` runs the whole gate (scripts/verify/m27).
CONFORMANCE_NET = $(shell docker inspect mini-baas-postgres --format '{{range $$k,$$v := .NetworkSettings.Networks}}{{$$k}}{{end}}' 2>/dev/null | head -1)
conformance-%: _rust-toolchain ## Rust: run the engine-conformance battery for ONE engine (e.g. make conformance-postgresql)
	@bash scripts/verify/m27-conformance.sh $*
conformance: ## Rust: run the engine-conformance gate for every live engine (m27)
	@bash scripts/verify/m27-conformance.sh
rust-data-plane-build: _rust-toolchain ## Rust: build the data-plane release binary (in Docker)
	@$(CARGO_DPR) cargo build --release --bin data-plane-router

# ── binocle-nano: the single-binary PocketBase-class edition ────────────────
# One static musl binary (embedded SQLite, in-process auth, SSE realtime) in
# a FROM scratch image — measured ~5 MB image / ~2 MiB idle RSS. Gate: m37.
nano-build: ## Nano: build the binocle-nano scratch image (static musl, ~5 MB)
	@DOCKER_BUILDKIT=1 docker build -f docker/services/data-plane-router/Dockerfile.nano \
		-t binocle-nano docker/services/data-plane-router
	@docker images binocle-nano --format '$(_G)✓ binocle-nano built — {{.Size}}$(_0)'

nano-up: nano-build ## Nano: run binocle-nano on :8090 (named volume nano-data)
	@docker rm -f binocle-nano >/dev/null 2>&1 || true
	@docker run -d --name binocle-nano -p 8090:8090 -v nano-data:/data binocle-nano >/dev/null
	@sleep 1; docker logs binocle-nano 2>&1 | head -5
	@echo -e "$(_G)✓ binocle-nano on http://localhost:8090 (admin key above on FIRST boot only)$(_0)"

nano-down: ## Nano: stop binocle-nano (data volume persists)
	@docker rm -f binocle-nano >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ binocle-nano stopped (volume nano-data kept)$(_0)"

# ── binocle-one: "our PocketBase" — nano + user accounts (JWT). Gate: m40. ──
one-build: ## One: build the binocle-one scratch image (nano + accounts)
	@DOCKER_BUILDKIT=1 docker build -f docker/services/data-plane-router/Dockerfile.one \
		-t binocle-one docker/services/data-plane-router
	@docker images binocle-one --format '$(_G)✓ binocle-one built — {{.Size}}$(_0)'

one-up: one-build ## One: run binocle-one on :8091 (named volume one-data)
	@docker rm -f binocle-one >/dev/null 2>&1 || true
	@docker run -d --name binocle-one -p 8091:8090 -v one-data:/data binocle-one >/dev/null
	@sleep 1; docker logs binocle-one 2>&1 | head -5
	@echo -e "$(_G)✓ binocle-one on http://localhost:8091 (admin key above on FIRST boot only)$(_0)"

one-down: ## One: stop binocle-one (data volume persists)
	@docker rm -f binocle-one >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ binocle-one stopped (volume one-data kept)$(_0)"

rust-realtime-check: _rust-toolchain ## Rust: cargo check the realtime workspace (in Docker)
	@$(CARGO_REALTIME) cargo check --workspace
rust-realtime-test: _rust-toolchain ## Rust: run the realtime unit tests (in Docker)
	@$(CARGO_REALTIME) cargo test --workspace
rust-realtime-build: _rust-toolchain ## Rust: build the realtime-server release binary (in Docker)
	@$(CARGO_REALTIME) cargo build --release --bin realtime-server
go-control-plane-check: ## Go: vet + test the control-plane module (in Docker, cached modules)
	@docker run --rm -v "$(CURDIR)/go/control-plane":/src -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
		golang:1.23-bookworm sh -c 'GOFLAGS=-mod=mod go vet ./... && GOFLAGS=-mod=mod go test ./...'
go-control-plane-build: ## Go: build the control-plane images
	@$(DC) --profile go-control-plane build

# ========================================================================== #
##@ Ops
# ========================================================================== #
preflight: ## Run pre-deployment checks
	@bash scripts/preflight-check.sh
hooks: ## Activate git hooks
	@if [ -d .git ]; then git config --local core.hooksPath $(HOOKS_DIR); chmod +x $(HOOKS_DIR)/* 2>/dev/null || true; echo -e "  $(_G)✓$(_0) hooks → $(HOOKS_DIR)"; else echo "  • not a git repo"; fi
update: ## Update git submodules
	@git submodule update --remote --merge && echo -e "$(_G)✓ Submodules updated$(_0)"

legacy-%: ## Run any target from the preserved Makefile.legacy
	@$(MAKE) -f Makefile.legacy $*

backup-now: ## Take a one-off Postgres backup right now (pg-backup `once` → MinIO)
	@echo -e "$(_B)Running an on-demand backup (pg-backup once)…$(_0)"
	@docker compose --profile backups run --rm pg-backup once \
		&& echo -e "$(_G)✓ backup complete — under the configured MinIO bucket$(_0)"

restore-verify: ## Prove a backup restores (dump→drop→restore→checksum, scratch DB; tenant data untouched)
	@bash scripts/verify/m47-backup-restore.sh

cloud-flags-print: ## Print the managed-cloud flag manifest (B7.1 single flip point — OPT-IN, no behaviour)
	@cat config/cloud/flags.env.example
	@echo ""
	@echo -e "$(_D)Opt-in: the default stack ignores this manifest (all flags default OFF in code = byte-parity).$(_0)"
	@echo -e "$(_D)Promotion ladder (staging→canary→prod): config/cloud/README.md$(_0)"

# ── Cloud edition (managed-cloud, all flags ON, mock Stripe) ─────────────────
# The env-only overlay docker-compose.cloud.yml + config/cloud/flags.env.cloud
# layered onto the default compose with the EDITION=prod planes + the `cloud`
# profile (stripe-mock). OPT-IN: a non-cloud `make up` never passes these `-f`s,
# so the default stack stays byte-parity (kernel #5). Design: wiki/cloud-edition-design.md.
CLOUD_FILES     := -f $(COMPOSE_FILE) -f docker-compose.cloud.yml
CLOUD_PROFILES  := --profile control-plane --profile go-control-plane \
                   --profile rust-data-plane --profile adapter-plane \
                   --profile background --profile storage --profile realtime \
                   --profile observability --profile ops --profile backups \
                   --profile cloud

cloud-up: _require-compose _rm-stale ## Boot the FULL managed-cloud stack locally (all cloud flags ON, mock Stripe)
	@echo -e "$(_B)Starting CLOUD edition (all managed-cloud flags ON, mock Stripe) → prod planes + cloud profile$(_0)"
	@eval "$$(bash scripts/resolve-ports.sh 2>/dev/null || true)"; \
	  docker compose $(CLOUD_FILES) $(CLOUD_PROFILES) up -d $(SERVICE)
	@echo -e "$(_G)✓ Cloud edition up (config/cloud/flags.env.cloud layered; stripe-mock in the cloud profile)$(_0)"

cloud-down: _require-compose ## Stop the cloud edition (overlay + cloud profile)
	@docker compose $(CLOUD_FILES) $(CLOUD_PROFILES) down
	@echo -e "$(_G)✓ Cloud edition down$(_0)"

# ========================================================================== #
##@ Release
# ========================================================================== #
# v1.0 release machinery (RELEASE.md is the checklist authority). The GitHub
# pipeline (.github/workflows/baas-release.yml at the monorepo root) fires on
# baas-v* tags; these targets are its local mirror for dry-runs and operators.
VERSION ?=

_require-version:
	@if [ -z "$(VERSION)" ]; then \
		echo -e "$(_R)VERSION is required (e.g. make release-images VERSION=1.0.0)$(_0)"; exit 1; fi

quickstart: ## One command to a running stack: .env → up PACKAGE (default essential) → health
	@[ -f .env ] || $(MAKE) env
	@$(MAKE) up PACKAGE=$(or $(PACKAGE),essential)
	@$(MAKE) health
	@echo ""
	@echo -e "$(_G)$(_W)✓ Grobase BaaS is up$(_0)"
	@echo -e "  Gateway:  $(_C)http://localhost:8000$(_0)"
	@echo -e "  API key:  $(_D)grep '^KONG_PUBLIC_API_KEY=' .env | cut -d= -f2$(_0)"
	@echo -e "  Try:      $(_D)curl http://localhost:8000/auth/v1/health -H \"apikey: <key>\"$(_0)"
	@echo -e "  Docs:     $(_D)QUICKSTART.md · DEPLOYMENT.md · SECURITY.md$(_0)"

release-binaries: nano-build one-build ## Release: extract binocle binaries + sha256 → artifacts/release/ (linux-amd64)
	@mkdir -p artifacts/release
	@for ed in nano one; do \
		cid=$$(docker create binocle-$$ed); \
		docker cp "$$cid:/binocle-$$ed" artifacts/release/binocle-$$ed; \
		docker rm -f "$$cid" >/dev/null; \
		chmod +x artifacts/release/binocle-$$ed; \
	done
	@cd artifacts/release && sha256sum binocle-nano binocle-one | tee checksums.txt
	@echo -e "$(_G)✓ binaries in artifacts/release/ (linux-amd64, FROM-scratch static musl)$(_0)"

release-images: _require-version ## Release: bake + push all suite images to GHCR (VERSION=x.y.z)
	@TAG=$(VERSION) docker buildx bake --push --set "*.platform=linux/amd64" -f docker-bake.hcl default
	@echo -e "$(_G)✓ pushed ghcr.io/univers42/mini-baas/*:$(VERSION) (amd64)$(_0)"

release-check: ## Release: run the pre-tag gate checklist (see RELEASE.md)
	@echo -e "$(_B)Pre-tag checklist (RELEASE.md is the authority)$(_0)"
	@$(MAKE) check-secrets
	@git -C "$(CURDIR)" status --porcelain | grep -q . \
		&& echo -e "  $(_R)✗ working tree dirty$(_0)" \
		|| echo -e "  $(_G)✓ working tree clean$(_0)"
	@[ -f scripts/install.sh ] && echo -e "  $(_G)✓ scripts/install.sh present$(_0)" \
		|| echo -e "  $(_R)✗ scripts/install.sh missing (release asset)$(_0)"
	@echo -e "  $(_D)Remaining (manual): make verify-all · CI green · SDK build+test · tag baas-vX.Y.Z$(_0)"

# ========================================================================== #
##@ Help
# ========================================================================== #
help: ## Show this help
	@echo ""
	@echo -e "$(_W)$(_C)$(PROJECT) — layer/edition orchestrator$(_0)"
	@echo -e "$(_D)EDITION=$(EDITION)  ·  make planes  ·  make editions  ·  make doctor$(_0)"
	@awk 'BEGIN {FS=":.*##"} \
		/^##@/ { printf "\n$(_W)%s$(_0)\n", substr($$0,5) } \
		/^[a-zA-Z0-9_%.-]+:.*##/ { printf "  $(_G)%-22s$(_0) $(_D)%s$(_0)\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""
	@echo -e "$(_D)Generated per-plane verbs: up-<plane> down-<plane> restart-<plane> logs-<plane>$(_0)"
	@echo ""

.PHONY: all all-full clean fclean re up down restart ps logs pull build health \
        bench-startup bench-load bench-capacity bench-mem bench-compare scale-seed scale-teardown observe planes editions doctor tests test-postgres test-offers test-edge \
        verify-all parity waf-test migrate migrate-mongo migrate-mysql migrate-all \
        migrate-status seed-mongo seed-live-demo secrets secrets-validate secrets-rotate \
        check-secrets env vault-init vault-status vault-rotate nestjs-ci \
        rust-data-plane-check rust-data-plane-build go-control-plane-check \
        rust-realtime-check rust-realtime-test rust-realtime-build _rust-toolchain \
        go-control-plane-build preflight hooks update help \
        quickstart release-binaries release-images release-check _require-version \
        backup-now restore-verify cloud-flags-print cloud-up cloud-down \
        _require-docker _require-compose _rm-stale
