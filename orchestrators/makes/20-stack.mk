# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    20-stack.mk                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 23:00:04 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 23:00:06 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

up: _require-compose _rm-stale ## Start the selected EDITION (detached)
	@[ -f .env ] || { echo -e "$(_Y).env missing → generating (make env)…$(_0)"; $(MAKE) --no-print-directory env; }
	@[ -f certs/localhost.pem ] || { echo -e "$(_Y)TLS cert missing → generating (make certs)…$(_0)"; $(MAKE) --no-print-directory certs; }
	@echo -e "$(_B)Starting edition '$(_W)$(EDITION)$(_0)$(_B)' → profiles: $(_C)$(ACTIVE_PROFILES)$(_0)"
	@eval "$$(bash scripts/ops/resolve-ports.sh 2>/dev/null || true)"; $(DCE) up -d $(SERVICE)
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
	@p="$$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://')"; p="$${p:-8000}"; \
		curl -fsS http://localhost:$$p/auth/v1/health >/dev/null && echo "  ✓ /auth/v1/health" || echo "  ✗ /auth/v1/health"; \
		curl -fsS http://localhost:$$p/rest/v1/ >/dev/null && echo "  ✓ /rest/v1/" || echo "  ✗ /rest/v1/"

bench-startup: _require-compose _rm-stale ## Time the stack until health checks pass (target ≤90s)
	@t0=$$(date +%s); eval "$$(bash scripts/ops/resolve-ports.sh 2>/dev/null || true)"; $(DCE) up -d; \
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
		-v "$(CURDIR)":/b -w /b public.ecr.aws/docker/library/node:22-bookworm \
		node /b/scripts/report/master-report.mjs \
			--infra /b --out /b/wiki/reports/comparison-report.html
	@echo -e "$(_G)$(_W)✓ comparison report → wiki/reports/comparison-report.html$(_0)"

# All HTML reports flow through ONE design system (scripts/lib/lib-report.mjs):
# styled, graphics-rich (inline SVG), zero-dep, CSP-safe. `make reports` regenerates
# the whole wiki/reports/ suite + the portal index — the reproducible single command.
# arg-less generators (each resolves its own data/out paths from import.meta.url)
REPORT_GENS := supabase-verdict-report security-wins-report network-controls-report compliance-posture-report edge-reliability-report benchmark-resources-report allmetrics-verdict-report
reports: master-report ## Regenerate EVERY HTML report (comparison + supabase-verdict + security/network/compliance wins) + portal (zero-dep, no host node)
	@for g in $(REPORT_GENS); do \
		echo "  → $$g"; \
		docker run --rm -u "$(shell id -u):$(shell id -g)" \
			-v "$(CURDIR)":/b -w /b public.ecr.aws/docker/library/node:22-bookworm \
			node /b/scripts/report/$$g.mjs || exit 1; \
	done
	@docker run --rm -u "$(shell id -u):$(shell id -g)" \
		-v "$(CURDIR)":/b -w /b public.ecr.aws/docker/library/node:22-bookworm \
		node /b/scripts/report/portal.mjs \
			--data /b/scripts/bench/offers-compare-data.json \
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
	docker run --rm --network host -v "$(CURDIR)/src/control-plane":/src -v "$(CURDIR)/artifacts":/artifacts -w /src \
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
	docker run --rm --network host -v "$(CURDIR)/src/control-plane":/src -v "$(CURDIR)/artifacts":/artifacts -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
		-e SERVICE_TOKEN_MODE="$$TMODE" golang:1.25-bookworm \
		go run ./cmd/scale-seed -teardown -base "http://127.0.0.1:$$TC_PORT" -token "$$TOKEN" \
		-out "/artifacts/scale/tenants-$$SCALE.jsonl"

audit-deps: ## Supply-chain CVE scan — cargo-audit (Rust) + govulncheck (Go)
	@bash scripts/security/audit-deps.sh
