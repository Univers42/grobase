SHELL          := /bin/bash
.SHELLFLAGS    := -ec
.DEFAULT_GOAL  := help

# --------------------------------------------------------------------------- #
#  Variables                                                                   #
# --------------------------------------------------------------------------- #

PROJECT        := mini-baas

# Colors
_B := \033[0;34m
_G := \033[0;32m
_Y := \033[1;33m
_R := \033[0;31m
_C := \033[0;36m
_W := \033[1m
_D := \033[2m
_0 := \033[0m

# Tunables  (override via CLI: make up COMPOSE_FILE=docker-compose.prod.yml)
IMAGE_TAG      ?= latest
REGISTRY       ?= localhost:5000
COMPOSE_FILE   ?= docker-compose.yml
SERVICE        ?=
STEPS          ?= 1
HOOKS_DIR      := vendor/scripts/hooks
NODE_IMAGE     ?= node:20-alpine

# Image map — local_name=upstream_ref  (single source of truth, pinned versions)
IMAGES_CORE := \
	kong=kong:3.8 \
	gotrue=supabase/gotrue:v2.188.1 \
	postgrest=postgrest/postgrest:v12.2.3 \
	postgres=postgres:16-alpine \
	realtime=dlesieur/realtime-agnostic:latest \
	redis=redis:7-alpine \
	mongo=mongo:7

IMAGES_EXTRAS := \
	trino=trinodb/trino:467 \
	pg-meta=supabase/postgres-meta:v0.91.0 \
	minio=minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1 \
	supavisor=supabase/supavisor:2.7.4 \
	studio=supabase/studio:2026.03.30-sha-12a43e5

# Set PROFILES=extras to include minio, supavisor, studio
PROFILES       ?=
ifneq ($(PROFILES),)
  IMAGES := $(IMAGES_CORE) $(IMAGES_EXTRAS)
  DC     := docker compose -f $(COMPOSE_FILE) --profile $(PROFILES)
else
  IMAGES := $(IMAGES_CORE)
  DC     := docker compose -f $(COMPOSE_FILE)
endif

# --------------------------------------------------------------------------- #
#  Internal prerequisites (no ## = hidden from help)                           #
# --------------------------------------------------------------------------- #

_require-docker:
	@command -v docker >/dev/null 2>&1 \
		|| { echo >&2 "Docker is not installed. Install Docker Engine/Desktop first."; exit 1; }

_require-compose: _require-docker
	@docker compose version >/dev/null 2>&1 \
		|| { echo >&2 "Docker Compose v2 plugin is required."; exit 1; }

_ensure-env:
	@if [ ! -f .env ]; then \
		echo -e "$(_Y).env not found; generating local development secrets…$(_0)"; \
		bash scripts/generate-env.sh .env; \
	fi

_rm-stale:
	@ids=$$(docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' \
		| awk '/ mini-baas-/ && ($$3=="Created"||$$3=="Exited") {print $$1}'); \
	[ -z "$$ids" ] || { echo -e "$(_Y)Removing stale containers…$(_0)"; docker rm -f $$ids >/dev/null; }
# ========================================================================== #
##@ 42 Classics
# ========================================================================== #

all: ## Build/pull core images & start stack (PROFILES=extras for full)
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory up

all-full: ## Build/pull ALL images & start full stack
	@$(MAKE) --no-print-directory PROFILES=extras all

clean: down ## Stop the stack (alias for down)

fclean: _require-compose ## Full cleanup — stop everything, prune containers, volumes, images and cache
	@echo -e "$(_Y)$(_W)Running destructive Docker cleanup…$(_0)"
	@$(DC) down --volumes --remove-orphans 2>/dev/null || true
	@ids=$$(docker ps -aq); \
	[ -z "$$ids" ] || { echo -e "$(_Y)Removing all Docker containers…$(_0)"; docker rm -f $$ids >/dev/null 2>&1 || true; }
	@docker system prune -af --volumes >/dev/null 2>&1 || true
	@docker builder prune -af >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ Full Docker clean complete$(_0)"

ffclean: _require-compose ## EXTREME cleanup — purge ALL Docker containers, images, volumes, networks and caches
	@echo -e "$(_R)$(_W)⚠ EXTREME DOCKER PURGE$(_0)"
	@echo -e "$(_R)This removes ALL Docker containers, images, volumes, unused networks and build caches on this machine.$(_0)"
	@echo -e "$(_R)It is NOT limited to $(PROJECT). Data in Docker volumes will be destroyed.$(_0)"
	@if [ "$${SKIP_FFCLEAN_DELAY:-0}" != "1" ]; then \
		for i in 5 4 3 2 1; do \
			echo -e "$(_Y)Starting irreversible purge in $$i… Ctrl+C to abort$(_0)"; \
			sleep 1; \
		done; \
	fi
	@$(DC) down --volumes --remove-orphans 2>/dev/null || true
	@ids=$$(docker ps -aq); \
	[ -z "$$ids" ] || { echo -e "$(_Y)Removing ALL containers…$(_0)"; docker rm -f $$ids >/dev/null 2>&1 || true; }
	@vols=$$(docker volume ls -q); \
	[ -z "$$vols" ] || { echo -e "$(_Y)Removing ALL volumes…$(_0)"; docker volume rm -f $$vols >/dev/null 2>&1 || true; }
	@imgs=$$(docker images -aq); \
	[ -z "$$imgs" ] || { echo -e "$(_Y)Removing ALL images…$(_0)"; docker rmi -f $$imgs >/dev/null 2>&1 || true; }
	@echo -e "$(_Y)Pruning networks, system data and build caches…$(_0)"
	@docker network prune -f >/dev/null 2>&1 || true
	@docker builder prune -af >/dev/null 2>&1 || true
	@docker buildx prune -af --all >/dev/null 2>&1 || true
	@docker system prune -af --volumes >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ Extreme Docker purge complete$(_0)"

re: ## Fully reset Docker state via fclean, then rebuild and restart the stack
	@$(MAKE) --no-print-directory fclean
	@$(MAKE) --no-print-directory all

# ========================================================================== #
##@ Stack
# ========================================================================== #

up: _require-compose _ensure-env _rm-stale ## Start stack in detached mode
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	echo -e "$(_B)Starting stack from $(COMPOSE_FILE)…$(_0)"; \
	$(DC) up -d; \
	echo -e "$(_G)✓ Stack started$(_0)"
bench-startup: _require-compose _rm-stale ## Time core stack startup until all health checks pass
	@echo -e "$$(_B)Benchmarking core stack startup…$$(_0)"
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	t0=$$(date +%s); \
	$(DC) up -d; \
	SERVICES="mini-baas-postgres mini-baas-mongo mini-baas-gotrue mini-baas-postgrest mini-baas-kong mini-baas-mongo-api mini-baas-realtime mini-baas-adapter-registry mini-baas-query-router mini-baas-permission-engine mini-baas-schema-service mini-baas-waf"; \
	for svc in $$SERVICES; do \
		printf "  Waiting: %-30s" "$$svc"; \
		timeout 120 sh -c "\
			while [ \"$$(docker inspect --format='{{.State.Health.Status}}' $$svc 2>/dev/null)\" != 'healthy' ]; do \
				sleep 1; \
			done" 2>/dev/null \
		&& echo -e "$$(_G)✓$$(_0)" \
		|| echo -e "$$(_R)✗ (timeout)$$(_0)"; \
	done; \
	t1=$$(date +%s); \
	elapsed=$$((t1 - t0)); \
	if [ "$$elapsed" -le 90 ]; then \
		echo -e "\n$$(_G)$$(_W)✓ All healthy in $${elapsed}s (target ≤90s)$$(_0)"; \
	else \
		echo -e "\n$$(_R)$$(_W)✗ Took $${elapsed}s — exceeds 90s target$$(_0)"; \
	fi
down: _require-compose ## Stop and remove stack resources
	@echo -e "$(_Y)Stopping stack…$(_0)"
	@$(DC) down
	@echo -e "$(_G)✓ Stack stopped$(_0)"

restart: _require-compose ## Restart all services
	@$(DC) restart
	@echo -e "$(_G)✓ Restarted$(_0)"

ps: _require-compose ## Show service status
	@$(DC) ps

dok-status: _require-compose ## Show Docker containers, health, images, volumes, networks and disk usage
	@echo -e "$(_C)$(_W)Docker engine$(_0)"
	@docker version --format '  Client: {{.Client.Version}}  Server: {{.Server.Version}}' 2>/dev/null || docker version
	@echo ""
	@echo -e "$(_C)$(_W)Compose services ($(PROJECT))$(_0)"
	@$(DC) ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || $(DC) ps
	@echo ""
	@echo -e "$(_C)$(_W)Container health details ($(PROJECT))$(_0)"
	@containers=$$(docker ps -a --filter label=com.docker.compose.project=$(PROJECT) --format '{{.Names}}'); \
	if [ -z "$$containers" ]; then \
		echo "  No $(PROJECT) containers found"; \
	else \
		printf '  %-34s %-12s %-12s %-20s\n' 'CONTAINER' 'STATE' 'HEALTH' 'IMAGE'; \
		for name in $$containers; do \
			state=$$(docker inspect -f '{{.State.Status}}' "$$name" 2>/dev/null || echo unknown); \
			health=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$$name" 2>/dev/null || echo unknown); \
			image=$$(docker inspect -f '{{.Config.Image}}' "$$name" 2>/dev/null || echo unknown); \
			printf '  %-34s %-12s %-12s %-20s\n' "$$name" "$$state" "$$health" "$$image"; \
		done; \
	fi
	@echo ""
	@echo -e "$(_C)$(_W)All Docker containers$(_0)"
	@docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
	@echo ""
	@echo -e "$(_C)$(_W)Images$(_0)"
	@docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'
	@echo ""
	@echo -e "$(_C)$(_W)Volumes$(_0)"
	@docker volume ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
	@echo ""
	@echo -e "$(_C)$(_W)Networks$(_0)"
	@docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
	@echo ""
	@echo -e "$(_C)$(_W)Docker disk usage$(_0)"
	@docker system df

logs: _require-compose ## Stream logs (SERVICE=<name> to filter)
	@$(DC) logs -f --tail=100 $(SERVICE)

pull: _require-compose ## Pull latest images for all services
	@$(DC) pull
	@echo -e "$(_G)✓ Pulled$(_0)"

fly-deploy: ## Deploy Fly apps (SERVICE=name optional, FLY_APP_PREFIX=mini-baas)
	@services="$${SERVICE:-}"; \
	if [ -n "$$services" ]; then \
		bash scripts/fly/deploy.sh $$services; \
	else \
		bash scripts/fly/deploy.sh; \
	fi

fly-secrets: _ensure-env ## Push per-service Fly secrets from .env (SERVICE=name optional)
	@services="$${SERVICE:-}"; \
	if [ -n "$$services" ]; then \
		bash scripts/fly/secrets-from-env.sh $$services; \
	else \
		bash scripts/fly/secrets-from-env.sh; \
	fi

fly-status: ## Show Fly app status (SERVICE=name optional)
	@services="$${SERVICE:-}"; \
	if [ -n "$$services" ]; then \
		bash scripts/fly/status.sh $$services; \
	else \
		bash scripts/fly/status.sh; \
	fi

fly-smoke: ## Smoke-test deployed gateway (BAAS_URL=https://api.example.com)
	@bash scripts/fly/smoke.sh

health: _ensure-env ## Quick health-check on gateway routes
	@echo -e "$(_B)Checking endpoints…$(_0)"
	@anon=$$(grep '^ANON_KEY=' .env | cut -d= -f2-); \
	curl -fsS -H "apikey: $$anon" -H "Authorization: Bearer $$anon" http://localhost:8000/auth/v1/health >/dev/null \
		&& echo "  ✓ /auth/v1/health" || echo "  ✗ /auth/v1/health"
	@anon=$$(grep '^ANON_KEY=' .env | cut -d= -f2-); \
	curl -fsS -H "apikey: $$anon" -H "Authorization: Bearer $$anon" http://localhost:8000/rest/v1/ >/dev/null \
		&& echo "  ✓ /rest/v1/"       || echo "  ✗ /rest/v1/"
	@docker compose exec -T postgres pg_isready -U postgres -d postgres >/dev/null \
		&& echo "  ✓ postgres ready"   || echo "  ✗ postgres ready"

# ========================================================================== #
##@ Docker Images
# ========================================================================== #

build: _require-docker ## Pull & tag all prebuilt images
	@echo -e "$(_B)Pulling and tagging prebuilt images…$(_0)"
	@pids=""; for pair in $(IMAGES); do \
		( \
			name=$${pair%%=*}; src=$${pair#*=}; \
			tag=$(PROJECT)/$$name:$(IMAGE_TAG); \
			if docker image inspect "$$tag" >/dev/null 2>&1; then \
				echo -e "  $(_G)●$(_0) $$name  (cached)"; \
			else \
				echo -e "  $(_Y)↓$(_0) $$name  ($${src})"; \
				t0=$$(date +%s); \
				if docker pull -q "$$src" >/dev/null; then \
					docker tag "$$src" "$$tag"; \
					t1=$$(date +%s); \
					echo -e "  $(_G)✓$(_0) $$name  [$$(( t1 - t0 ))s]"; \
				else \
					echo -e "  $(_R)✗$(_0) $$name  FAILED"; \
					exit 1; \
				fi; \
			fi \
		) & pids="$$pids $$!"; \
	done; \
	fail=0; for p in $$pids; do wait "$$p" || fail=1; done; \
	[ "$$fail" -eq 0 ] || { echo -e "$(_R)✗ Some pulls failed — check output above$(_0)"; exit 1; }
	@echo -e "$(_G)✓ All images ready$(_0)"

build-%: _require-docker ## Pull/tag one image (e.g. make build-kong)
	@src=""; for pair in $(IMAGES); do \
		n=$${pair%%=*}; [ "$$n" = "$*" ] && src=$${pair#*=} && break; \
	done; \
	[ -n "$$src" ] || { echo -e "$(_R)Unknown image: $*$(_0)"; exit 1; }; \
	echo -e "$(_B)Pulling $*…$(_0)"; \
	docker pull "$$src"; \
	docker tag "$$src" $(PROJECT)/$*:$(IMAGE_TAG); \
	echo -e "$(_G)✓ $* ready$(_0)"

build-optimized: _require-docker ## BuildKit parallel build with inline cache
	@DOCKER_BUILDKIT=1 $(DC) build --build-arg BUILDKIT_INLINE_CACHE=1 --parallel
	@echo -e "$(_G)✓ Optimized build complete$(_0)"

tag: _require-docker ## Tag images for REGISTRY
	@echo -e "$(_B)Tagging for $(REGISTRY)…$(_0)"
	@for pair in $(IMAGES); do \
		name=$${pair%%=*}; \
		docker tag $(PROJECT)/$$name:$(IMAGE_TAG) $(REGISTRY)/$$name:$(IMAGE_TAG); \
	done
	@echo -e "$(_G)✓ Tagged$(_0)"

push: tag ## Tag & push all images to REGISTRY
	@echo -e "$(_B)Pushing to $(REGISTRY)…$(_0)"
	@for pair in $(IMAGES); do \
		name=$${pair%%=*}; \
		docker push $(REGISTRY)/$$name:$(IMAGE_TAG); \
	done
	@echo -e "$(_G)✓ Pushed$(_0)"

push-bake: ## Build & push via docker buildx bake
	@docker buildx bake --file docker-bake.hcl --push \
		--set "*.cache-to=type=registry,ref=$(REGISTRY)/cache,mode=max"
	@echo -e "$(_G)✓ Bake push to $(REGISTRY) complete$(_0)"

images: _require-docker ## List local $(PROJECT) images
	@docker images | grep $(PROJECT) || echo "No images found. Run 'make build'."

image-sizes: ## Show image sizes for the stack
	@echo -e "$(_B)Image sizes:$(_0)"
	@$(DC) images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' 2>/dev/null \
		|| docker images --filter=reference='$(PROJECT)*' \
			--format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'

tests: ## Run all smoke tests (phase 1→15)
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	export PUBLIC_APIKEY=$${PUBLIC_APIKEY:-$$APIKEY}; \
	export SERVICE_ROLE_KEY=$${SERVICE_ROLE_KEY:-$$(grep '^SERVICE_ROLE_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	total_p=0; total_f=0; rc_all=0; \
	for script in $$(ls -1 ./scripts/phase*-*.sh ./scripts/phase*-*.py 2>/dev/null | sort -t/ -k3 -V); do \
		[ -f "$$script" ] || continue; \
		tmp=$$(mktemp); \
		case "$$script" in \
			*.py) FORCE_COLORS=1 python3 "$$script" | tee "$$tmp" ;; \
			*)    FORCE_COLORS=1 bash    "$$script" | tee "$$tmp" ;; \
		esac; \
		rc=$${PIPESTATUS[0]}; \
		clean=$$(sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "$$tmp"); \
		p=$$(printf '%s\n' "$$clean" | awk -F: '/Passed:/{gsub(/[^0-9]/,"",$$2);v=$$2}END{print v+0}'); \
		f=$$(printf '%s\n' "$$clean" | awk -F: '/Failed:/{gsub(/[^0-9]/,"",$$2);v=$$2}END{print v+0}'); \
		total_p=$$((total_p + p)); total_f=$$((total_f + f)); \
		rm -f "$$tmp"; \
		[ "$$rc" -eq 0 ] || rc_all=1; \
		sleep 2; \
	done; \
	echo ""; \
	echo -e "$(_C)$(_W)╔════════════════════════════════════════════════╗$(_0)"; \
	echo -e "$(_C)$(_W)║$(_0) $(_W)Tests Summary$(_0)"; \
	echo -e "$(_C)$(_W)╠════════════════════════════════════════════════╣$(_0)"; \
	echo -e "$(_C)$(_W)║$(_0) $(_G)$(_W)✔ Passed:$(_0) $(_G)$$total_p$(_0)"; \
	echo -e "$(_C)$(_W)║$(_0) $(_R)$(_W)✖ Failed:$(_0) $(_R)$$total_f$(_0)"; \
	echo -e "$(_C)$(_W)╚════════════════════════════════════════════════╝$(_0)"; \
	[ "$$rc_all" -eq 0 ] \
		&& echo -e "$(_G)$(_W)✔ All phases passed$(_0)" \
		|| { echo -e "$(_R)$(_W)✖ Some phases failed$(_0)"; exit 1; }

test-phase%: ## Run one phase (e.g. make test-phase3)
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	export PUBLIC_APIKEY=$${PUBLIC_APIKEY:-$$APIKEY}; \
	export SERVICE_ROLE_KEY=$${SERVICE_ROLE_KEY:-$$(grep '^SERVICE_ROLE_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	script=$$(ls scripts/phase$*-*.sh 2>/dev/null | head -1); \
	if [ -n "$$script" ]; then FORCE_COLORS=1 bash "$$script"; \
	else \
		script=$$(ls scripts/phase$*-*.py 2>/dev/null | head -1); \
		[ -n "$$script" ] && FORCE_COLORS=1 python3 "$$script" \
			|| { echo -e "$(_R)No test for phase $*$(_0)"; exit 1; }; \
	fi

test-postgres: ## Run PostgreSQL MVP happy-path flow
	@FORCE_COLORS=1 bash ./scripts/postgres-mvp-flow.sh

migrate: ## Run all pending PostgreSQL migrations
	@echo -e "$(_B)Running PostgreSQL migrations…$(_0)"
	@for f in $$(ls -1 scripts/migrations/postgresql/*.sql 2>/dev/null | sort); do \
		echo "  Applying: $$f"; \
		docker compose exec -T postgres psql -U postgres -d postgres -f /dev/stdin < "$$f"; \
	done
	@echo -e "$(_G)✓ PostgreSQL migrations applied$(_0)"

migrate-mongo: ## Run all MongoDB migrations
	@echo -e "$(_B)Running MongoDB migrations…$(_0)"
	@for f in $$(ls -1 scripts/migrations/mongodb/*.js 2>/dev/null | sort); do \
		echo "  Applying: $$f"; \
		docker compose exec -T mongo mongosh mini_baas < "$$f"; \
	done
	@echo -e "$(_G)✓ MongoDB migrations applied$(_0)"

seed-mongo: _require-compose ## Seed MongoDB with demo data
	@bash scripts/seed-mongo.sh

migrate-down: ## Show rollback hints (STEPS=1)
	@echo -e "$(_Y)Manual rollback required.$(_0)"
	@echo "Check DOWN comments in the last $(STEPS) migration(s):"
	@ls -1r scripts/migrations/postgresql/*.sql | head -n $(STEPS)

migrate-status: ## Show applied migration versions
	@docker compose exec -T postgres psql -U postgres -d postgres \
		-c "SELECT version, name, applied_at FROM schema_migrations ORDER BY version;" \
		2>/dev/null || echo "  No migrations table — run make migrate first."


secrets: ## Generate all secrets → .env
	@bash scripts/secrets/generate-secrets.sh

secrets-validate: ## Validate required secrets exist
	@bash scripts/secrets/validate-secrets.sh

secrets-rotate: ## Rotate JWT secret (zero-downtime)
	@bash scripts/secrets/rotate-jwt.sh

check-secrets: ## Scan source code for hardcoded secrets
	@bash scripts/check-secrets.sh

observe: _require-compose ## Start Prometheus + Grafana + Loki
	@$(DC) --profile observability up -d
	@echo -e "$(_G)✓ Observability started$(_0)"
	@echo -e "  Grafana:    http://localhost:3030"
	@echo -e "  Prometheus: http://localhost:9090"

observe-down: ## Stop observability stack
	@$(DC) --profile observability stop prometheus grafana loki promtail 2>/dev/null || true
	@echo -e "$(_G)✓ Observability stopped$(_0)"

grafana: ## Open Grafana in browser
	@xdg-open http://localhost:3030 2>/dev/null \
		|| open http://localhost:3030 2>/dev/null \
		|| echo "http://localhost:3030"

prometheus: ## Open Prometheus in browser
	@xdg-open http://localhost:9090 2>/dev/null \
		|| open http://localhost:9090 2>/dev/null \
		|| echo "http://localhost:9090"

adapter-add: ## Register a database  (ENGINE= NAME= DSN=)
	@curl -sS -X POST http://localhost:8000/admin/v1/databases \
		-H "apikey: $$(grep KONG_SERVICE_API_KEY .env | cut -d= -f2)" \
		-H "Content-Type: application/json" \
		-d '{"engine":"$(ENGINE)","name":"$(NAME)","connection_string":"$(DSN)"}'
	@echo ""

adapter-ls: ## List registered databases
	@curl -sS http://localhost:8000/admin/v1/databases \
		-H "apikey: $$(grep KONG_SERVICE_API_KEY .env | cut -d= -f2)" | jq .

play-css: ## Build libcss CSS assets
	@docker run --rm -v $(CURDIR)/vendor/libcss:/src:ro -v $(CURDIR)/vendor/libcss:/out -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --store-dir /pnpm-store && pnpm run build:min && cp -a dist /out/ 2>/dev/null || true'
	@echo -e "$(_G)✓ CSS ready$(_0)"

play: _require-compose play-css ## Build CSS & start playground
	@$(DC) up -d playground
	@echo -e "$(_G)✓ Playground → http://localhost:3100$(_0)"

play-down: _require-compose ## Stop playground
	@$(DC) stop playground 2>/dev/null || true
	@$(DC) rm -f playground  2>/dev/null || true
	@echo -e "$(_G)✓ Playground stopped$(_0)"

play-logs: _require-compose ## Stream playground logs
	@$(DC) logs -f --tail=100 playground

env: ## Generate .env from template
	@bash scripts/generate-env.sh

preflight: ## Run all pre-deployment checks
	@bash scripts/preflight-check.sh

hooks: ## Activate git hooks
	@if [ ! -d .git ]; then echo -e "  $(_Y)⚠$(_0) Not a git repo — skipping"; \
	else \
		cur=$$(git config --local core.hooksPath 2>/dev/null || echo ""); \
		if [ "$$cur" = "$(HOOKS_DIR)" ]; then \
			echo -e "  $(_G)✓$(_0) Git hooks active → $(HOOKS_DIR)"; \
		else \
			git config --local core.hooksPath $(HOOKS_DIR); \
			chmod +x $(HOOKS_DIR)/*; \
			echo -e "  $(_G)✓$(_0) Git hooks activated → $(HOOKS_DIR)"; \
		fi; \
		for old in commit-msg pre-commit pre-push post-checkout pre-merge-commit log_hook log_hook.sh; do \
			[ -L ".git/hooks/$$old" ] && rm -f ".git/hooks/$$old"; \
		done; \
	fi

update: ## Update git submodules
	@git submodule update --remote --merge
	@echo -e "$(_G)✓ Submodules updated$(_0)"

audit-scan: ## Run SonarCloud scanner (requires TOK_SONARCLOUD in .env)
	@echo -e "$(_B)Running SonarCloud scan…$(_0)"
	@SONAR_TOKEN=$$(grep TOK_SONARCLOUD .env | cut -d= -f2); \
	[ -n "$$SONAR_TOKEN" ] || { echo -e "$(_R)TOK_SONARCLOUD not found in .env$(_0)"; exit 1; }; \
	docker run --rm -e SONAR_TOKEN="$$SONAR_TOKEN" -v $(CURDIR):/usr/src sonarsource/sonar-scanner-cli \
		-Dsonar.token="$$SONAR_TOKEN" \
		-Dsonar.qualitygate.wait=true 2>&1 | tee audit/scan.log; \
	echo -e "$(_G)✓ Scan complete — log at audit/scan.log$(_0)"

audit-fetch: ## Fetch SonarCloud issues → audit/*.json + audit/summary.txt
	@SONAR_TOKEN=$$(grep TOK_SONARCLOUD .env | cut -d= -f2) \
		bash scripts/sonar-fetch-issues.sh

audit: audit-scan audit-fetch ## Full audit: scan + fetch issues
	@echo -e "$(_G)✓ Audit complete — see audit/summary.txt$(_0)"

nestjs-install: ## Install NestJS monorepo dependencies
	@echo -e "$(_B)Checking NestJS dependencies in Docker…$(_0)"
	@docker run --rm -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store'
	@echo -e "$(_G)✓ Dependencies install cleanly in Docker$(_0)"

nestjs-lint: ## Run ESLint on NestJS monorepo
	@echo -e "$(_B)Linting NestJS monorepo…$(_0)"
	@docker run --rm -v $(CURDIR)/src:/src -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec eslint "apps/**/*.ts" "libs/**/*.ts" --fix && cp -a apps libs /src/'
	@echo -e "$(_G)✓ Lint passed$(_0)"

nestjs-typecheck: ## TypeScript strict type-check (no emit)
	@echo -e "$(_B)Type-checking NestJS monorepo…$(_0)"
	@docker run --rm -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec tsc --noEmit'
	@echo -e "$(_G)✓ Type-check passed$(_0)"

nestjs-format: ## Prettier format check
	@docker run --rm -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec prettier --check "apps/**/*.ts" "libs/**/*.ts"'
	@echo -e "$(_G)✓ Format OK$(_0)"

nestjs-build: ## Build all NestJS apps
	@echo -e "$(_B)Building all NestJS apps…$(_0)"
	@docker run --rm -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec nest build adapter-registry && pnpm exec nest build mongo-api && pnpm exec nest build query-router && pnpm exec nest build email-service && pnpm exec nest build storage-router && pnpm exec nest build permission-engine && pnpm exec nest build schema-service'
	@echo -e "$(_G)✓ All apps built$(_0)"

nestjs-build-%: ## Build one NestJS app (e.g. make nestjs-build-mongo-api)
	@echo -e "$(_B)Building $*…$(_0)"
	@docker run --rm -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec nest build $*'
	@echo -e "$(_G)✓ $* built$(_0)"

nestjs-dev-%: ## Run one NestJS app locally in dev mode (e.g. make nestjs-dev-mongo-api)
	@docker run --rm -it -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec nest start $* --watch'

nestjs-test: ## Run all NestJS unit tests
	@docker run --rm -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec jest --passWithNoTests'
	@echo -e "$(_G)✓ Tests passed$(_0)"

nestjs-ci: nestjs-install nestjs-typecheck nestjs-lint nestjs-test ## Full NestJS CI pipeline

vault-init: _require-compose ## Run Vault init/unseal/seed manually
	@echo -e "$(_B)Initializing Vault…$(_0)"
	@$(DC) run --rm vault-init
	@echo -e "$(_G)✓ Vault initialized$(_0)"

vault-status: _require-compose ## Check Vault seal status
	@docker exec mini-baas-vault vault status -address=http://127.0.0.1:8200 2>/dev/null \
		|| echo -e "$(_R)Vault not running$(_0)"

vault-unseal: _require-compose ## Unseal Vault with root key from .vault-keys
	@key=$$(grep 'Unseal Key' .vault-keys 2>/dev/null | awk '{print $$NF}'); \
	[ -n "$$key" ] && docker exec mini-baas-vault vault operator unseal -address=http://127.0.0.1:8200 "$$key" \
		|| echo -e "$(_Y)No .vault-keys found — run make vault-init first$(_0)"

vault-rotate: _require-compose ## Rotate all Vault secrets (GROUP=jwt|postgres|mongo|minio|kong|all)
	@echo -e "$(_B)Rotating Vault secrets (group: $${GROUP:-all})…$(_0)"
	@docker exec mini-baas-vault /vault/scripts/rotate-secrets.sh $${GROUP:-all}
	@echo -e "$(_G)✓ Vault rotation complete$(_0)"

vault-rotate-dry: _require-compose ## Dry-run secret rotation (preview without applying)
	@docker exec -e DRY_RUN=1 mini-baas-vault /vault/scripts/rotate-secrets.sh $${GROUP:-all}

waf-logs: _require-compose ## Stream WAF (ModSecurity) logs
	@$(DC) logs -f --tail=200 waf

waf-test: ## Quick WAF attack test (should be blocked)
	@echo -e "$(_B)Testing WAF blocks…$(_0)"
	@status=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost/rest/v1/?id=1%20OR%201=1"); \
	if [ "$$status" = "403" ]; then \
		echo -e "  $(_G)✓$(_0) SQL injection blocked (HTTP 403)"; \
	else \
		echo -e "  $(_R)✗$(_0) Expected 403, got $$status"; \
	fi
	@status=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost/rest/v1/<script>alert(1)</script>"); \
	if [ "$$status" = "403" ]; then \
		echo -e "  $(_G)✓$(_0) XSS blocked (HTTP 403)"; \
	else \
		echo -e "  $(_R)✗$(_0) Expected 403, got $$status"; \
	fi

watch: _require-compose _rm-stale ## Build, start stack & launch interactive observatory
	@echo -e "$(_B)Stopping previous stack to ensure clean start…$(_0)"
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	$(DC) down --remove-orphans 2>/dev/null || true
	@echo -e "$(_B)Building & starting stack…$(_0)"
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	$(DC) up -d --build 2>&1 | grep -v "^$$" || echo -e "$(_Y)⚠  Some containers may need time — observatory will show details$(_0)"
	@echo -e "$(_G)▶ Starting mini-BaaS Observatory (interactive)…$(_0)"
	docker run --rm -it -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec ts-node -r tsconfig-paths/register tools/observatory.ts'

watch-logs: _require-compose _rm-stale ## Build, start stack & stream logs only (no interactive prompt)
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	$(DC) down --remove-orphans 2>/dev/null || true
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	$(DC) up -d --build 2>&1 | tail -5 || true
	@echo -e "$(_G)▶ Starting log stream…$(_0)"
	docker run --rm -it -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec ts-node -r tsconfig-paths/register tools/observatory.ts --logs'

watch-headless: _require-compose _rm-stale ## Build, start stack & launch observatory in background
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	$(DC) down --remove-orphans 2>/dev/null || true
	@eval "$$(bash scripts/resolve-ports.sh)"; \
	$(DC) up -d --build 2>&1 | tail -5 || true
	@echo -e "$(_G)▶ Starting headless observatory…$(_0)"
	@nohup docker run --rm -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec ts-node -r tsconfig-paths/register tools/observatory.ts --headless' \
		> ../observatory.log 2>&1 & echo "$$!" > ../.observatory.pid
	@echo -e "$(_G)  PID: $$(cat .observatory.pid)  •  Log: observatory.log$(_0)"
	@echo -e "$(_Y)  Use 'make kill-watch' to stop$(_0)"

kill-watch: ## Stop a headless observatory process
	@if [ -f .observatory.pid ]; then \
		pid=$$(cat .observatory.pid); \
		if kill -0 "$$pid" 2>/dev/null; then \
			kill "$$pid" && echo -e "$(_G)✓ Observatory (PID $$pid) stopped$(_0)"; \
		else \
			echo -e "$(_Y)Observatory (PID $$pid) is not running$(_0)"; \
		fi; \
		rm -f .observatory.pid; \
	else \
		echo -e "$(_Y)No .observatory.pid file found$(_0)"; \
	fi

watch-attach: ## Attach interactive observatory to an already-running stack (no build)
	@echo -e "$(_G)▶ Attaching mini-BaaS Observatory…$(_0)"
	docker run --rm -it -v $(CURDIR)/src:/src:ro -w /tmp $(NODE_IMAGE) sh -lc 'cp -a /src app && cd app && corepack enable >/dev/null && pnpm install --frozen-lockfile --store-dir /pnpm-store >/dev/null && pnpm exec ts-node -r tsconfig-paths/register tools/observatory.ts'

watch-docker: ## Simple docker compose log tail (all services)
	docker compose logs -f --tail=100

# ========================================================================== #
##@ Help
# ========================================================================== #

help: ## Show this help
	@echo ""
	@echo -e "$(_W)$(_C)$(PROJECT) — Available Commands$(_0)"
	@awk 'BEGIN {FS=":.*##"; printf ""} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) } \
		/^[a-zA-Z0-9_%.-]+:.*##/ { printf "  \033[1;32m%-20s\033[0m \033[2;37m%s\033[0m\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@echo ""

# --------------------------------------------------------------------------- #
.PHONY: all clean fclean ffclean re \
	up down restart ps dok-status logs pull health bench-startup \
	fly-deploy fly-secrets fly-status fly-smoke \
	build build-% build-optimized tag push push-bake images image-sizes \
	tests test-phase% test-postgres \
	migrate migrate-mongo migrate-down migrate-status seed-mongo \
	secrets secrets-validate secrets-rotate check-secrets \
	observe observe-down grafana prometheus \
	adapter-add adapter-ls \
	play play-css play-down play-logs \
	audit audit-scan audit-fetch \
	nestjs-install nestjs-lint nestjs-typecheck nestjs-format \
	nestjs-build nestjs-build-% nestjs-dev-% nestjs-test nestjs-ci \
	vault-init vault-status vault-unseal vault-rotate vault-rotate-dry \
	waf-logs waf-test \
	watch watch-logs watch-headless kill-watch watch-attach watch-docker \
	env preflight hooks update help \
	_require-docker _require-compose _ensure-env _rm-stale
