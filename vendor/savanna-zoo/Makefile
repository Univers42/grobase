# ============================================================
# Makefile — Savanna Park Zoo  (sandbox/apps/app2)
#
# One-command workflow to run the zoo website on the real BaaS:
#
#   make dev-all      Start BaaS + frontend together (background, logs)
#   make baas         Start only the BaaS backend (docker + seed)
#   make front        Start only the Vite frontend dev server
#   make turn-off     Shut down everything (BaaS + frontend + logs)
#   make all          Build the frontend, start BaaS, seed DB, serve
#   make seed         Seed the zoo database (re-runnable)
#   make reset        Drop + reseed the zoo database
#   make build        Build the Vite frontend to dist/
#   make serve        Serve the built frontend via Docker (nginx)
#   make down         Stop the zoo frontend container
#   make clean        Remove dist/ and stop container
#   make logs         Tail all logs (BaaS + frontend)
#   make logs-baas    Tail BaaS logs only
#   make logs-front   Tail frontend logs only
#   make status       Show BaaS stack + zoo container status
#   make help         Show this help
# ============================================================

# ── Paths ─────────────────────────────────────────────────────
ROOT_DIR    := $(shell cd ../../.. && pwd)
APP_DIR     := $(shell pwd)
FRONT_DIR   := $(APP_DIR)/front
INFRA_DIR   := $(APP_DIR)/infra

# ── BaaS connection (auto-read from root .env if present) ────
-include $(ROOT_DIR)/.env
PG_HOST     ?= localhost
PG_PORT     ?= 5432
PG_USER     ?= $(or $(POSTGRES_USER),postgres)
PG_PASS     ?= $(or $(POSTGRES_PASSWORD),postgres)
PG_DB       ?= $(or $(POSTGRES_DB),postgres)
# Auto-detect Kong host port (falls back to 8000)
KONG_PORT   ?= $(shell docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000)
KONG_URL    ?= http://localhost:$(KONG_PORT)
API_KEY     ?= $(or $(KONG_PUBLIC_API_KEY),public-anon-key)
ZOO_PASS    ?= zoo-admin-2024

export PG_HOST PG_PORT PG_USER PG_PASS PG_DB API_KEY

# ── Docker compose ───────────────────────────────────────────
DC          := docker compose
DC_ROOT     := $(DC) -f $(ROOT_DIR)/docker-compose.yml
DC_ZOO      := $(DC) -f $(APP_DIR)/docker-compose.yml

# ── PID / log files (for background processes) ───────────────
LOG_DIR     := $(APP_DIR)/.logs
BAAS_LOG    := $(LOG_DIR)/baas.log
FRONT_LOG   := $(LOG_DIR)/front.log
FRONT_PID   := $(LOG_DIR)/front.pid
BAAS_LOG_PID:= $(LOG_DIR)/baas-log.pid
# ─── Colours ─────────────────────────────────────────────────
G := \033[1;32m
Y := \033[1;33m
C := \033[1;36m
R := \033[0m

.PHONY: all dev dev-all baas front turn-off build serve seed reset down clean \
       logs logs-baas logs-front status baas-up baas-down help

# ── Default: full pipeline ────────────────────────────────────
all: build baas-up seed serve
	@printf "$(G)═══════════════════════════════════════════$(R)\n"
	@printf "$(G) ✓ Savanna Park Zoo is running!$(R)\n"
	@printf "$(G)   Website:   http://localhost:5180$(R)\n"
	@printf "$(G)   Dashboard: http://localhost:5180/dashboard$(R)\n"
	@printf "$(G)   Login:     sophie.laurent@savanna-zoo.com$(R)\n"
	@printf "$(G)   Password:  $(ZOO_PASS)$(R)\n"
	@printf "$(G)═══════════════════════════════════════════$(R)\n"

# ── Start BaaS infrastructure ────────────────────────────────
baas-up:
	@printf "$(Y)▸ Starting BaaS infrastructure …$(R)\n"
	@if [ ! -f "$(ROOT_DIR)/.env" ]; then \
		printf "$(Y)  Generating .env …$(R)\n"; \
		cd $(ROOT_DIR) && bash scripts/generate-env.sh; \
	fi
	@# Ensure CORS allows the zoo frontend origins (dev + prod)
	@if grep -q 'KONG_CORS_ORIGIN_APP=' "$(ROOT_DIR)/.env"; then \
		sed -i 's|KONG_CORS_ORIGIN_APP=.*|KONG_CORS_ORIGIN_APP=http://localhost:5173|' "$(ROOT_DIR)/.env"; \
		sed -i 's|KONG_CORS_ORIGIN_PLAYGROUND=.*|KONG_CORS_ORIGIN_PLAYGROUND=http://localhost:5180|' "$(ROOT_DIR)/.env"; \
	fi
	@# Avoid port conflict: if 8000 is busy (e.g. kubectl), remap Kong to 8001
	@if ss -tln | grep -q ':8000 '; then \
		if ! docker ps --format '{{.Names}}' | grep -q 'mini-baas-kong'; then \
			printf "$(Y)  Port 8000 in use — remapping Kong to 8001$(R)\n"; \
			if grep -q '^KONG_HTTP_PORT=' "$(ROOT_DIR)/.env"; then \
				sed -i 's|^KONG_HTTP_PORT=.*|KONG_HTTP_PORT=8001|' "$(ROOT_DIR)/.env"; \
			else \
				echo 'KONG_HTTP_PORT=8001' >> "$(ROOT_DIR)/.env"; \
			fi; \
		fi; \
	fi
	@# Avoid port conflict: if 4000 is busy, remap Realtime to 4002
	@if ss -tln | grep -q ':4000 '; then \
		if ! docker ps --format '{{.Names}}' | grep -q 'mini-baas-realtime'; then \
			printf "$(Y)  Port 4000 in use — remapping Realtime to 4002$(R)\n"; \
			if grep -q '^REALTIME_PORT=' "$(ROOT_DIR)/.env"; then \
				sed -i 's|^REALTIME_PORT=.*|REALTIME_PORT=4002|' "$(ROOT_DIR)/.env"; \
			else \
				echo 'REALTIME_PORT=4002' >> "$(ROOT_DIR)/.env"; \
			fi; \
		fi; \
	fi
	$(DC_ROOT) up -d
	@printf "$(Y)  Waiting for core services (postgres, kong, gotrue, postgrest) …$(R)\n"
	@for svc in postgres kong gotrue postgrest; do \
		for i in $$(seq 1 30); do \
			if docker inspect --format='{{.State.Health.Status}}' mini-baas-$$svc 2>/dev/null | grep -q healthy; then break; fi; \
			if docker inspect --format='{{.State.Status}}' mini-baas-$$svc 2>/dev/null | grep -q running; then \
				if ! docker inspect --format='{{.State.Health}}' mini-baas-$$svc 2>/dev/null | grep -q Status; then break; fi; \
			fi; \
			sleep 1; \
		done; \
	done
	@printf "$(G)  ✓ BaaS stack is running$(R)\n"

baas-down:
	$(DC_ROOT) down

# ══════════════════════════════════════════════════════════════
#  NEW: make baas / make front / make dev-all / make turn-off
# ══════════════════════════════════════════════════════════════

# ── make baas — start BaaS backend, seed DB, stream logs ─────
baas:
	@mkdir -p $(LOG_DIR)
	@printf "$(Y)▸ Starting BaaS backend …$(R)\n"
	@$(MAKE) --no-print-directory baas-up
	@$(MAKE) --no-print-directory seed
	@LIVE_PORT=$$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000); \
		printf "$(G)═══════════════════════════════════════════$(R)\n"; \
		printf "$(G) ✓ BaaS is running$(R)\n"; \
		printf "$(G)   API:   http://localhost:$$LIVE_PORT/rest/v1/$(R)\n"; \
		printf "$(G)   Auth:  http://localhost:$$LIVE_PORT/auth/v1/$(R)\n"; \
		printf "$(G)═══════════════════════════════════════════$(R)\n"
	@printf "$(C)▸ Streaming BaaS logs (Ctrl+C to detach) …$(R)\n"
	$(DC_ROOT) logs -f 2>&1 | tee $(BAAS_LOG)

# ── make front — install deps + start Vite dev server ────────
front:
	@printf "$(C)▸ Installing frontend dependencies …$(R)\n"
	@cd $(FRONT_DIR) && pnpm install --frozen-lockfile 2>/dev/null || cd $(FRONT_DIR) && pnpm install
	@printf "$(C)▸ Starting Vite dev server (http://localhost:5173) …$(R)\n"
	cd $(FRONT_DIR) && pnpm dev

# ── make dev-all — BaaS + frontend in background, tailed ─────
dev-all:
	@mkdir -p $(LOG_DIR)
	@printf "$(Y)═══════════════════════════════════════════$(R)\n"
	@printf "$(Y) Savanna Park Zoo — dev-all$(R)\n"
	@printf "$(Y)═══════════════════════════════════════════$(R)\n"
	@printf "\n"
	@# ── Step 1: Start the BaaS ──────────────────────────────
	@printf "$(Y)▸ [1/3] Starting BaaS infrastructure …$(R)\n"
	@$(MAKE) --no-print-directory baas-up
	@$(MAKE) --no-print-directory seed
	@LIVE_PORT=$$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000); \
		printf "$(G)  ✓ BaaS ready at http://localhost:$$LIVE_PORT$(R)\n\n"
	@# ── Step 2: Stream BaaS logs in background ──────────────
	@printf "$(Y)▸ [2/3] Starting BaaS log server …$(R)\n"
	@$(DC_ROOT) logs -f > $(BAAS_LOG) 2>&1 & LOGPID=$$!; echo $$LOGPID > $(BAAS_LOG_PID)
	@printf "$(G)  ✓ BaaS logs → .logs/baas.log$(R)\n\n"
	@# ── Step 3: Start Vite frontend in background ───────────
	@printf "$(Y)▸ [3/3] Starting Vite frontend dev server …$(R)\n"
	@cd $(FRONT_DIR) && pnpm install --frozen-lockfile 2>/dev/null || cd $(FRONT_DIR) && pnpm install
	@cd $(FRONT_DIR) && nohup pnpm dev > $(FRONT_LOG) 2>&1 & FPID=$$!; echo $$FPID > $(FRONT_PID)
	@sleep 3
	@printf "$(G)  ✓ Frontend logs → .logs/front.log$(R)\n\n"
	@LIVE_PORT=$$(docker port mini-baas-kong 8000/tcp 2>/dev/null | head -1 | sed 's/.*://' || echo 8000); \
		printf "$(G)═══════════════════════════════════════════$(R)\n"; \
		printf "$(G) ✓ Everything is running!$(R)\n"; \
		printf "$(G)$(R)\n"; \
		printf "$(G)   Frontend:  http://localhost:5173$(R)\n"; \
		printf "$(G)   BaaS API:  http://localhost:$$LIVE_PORT/rest/v1/$(R)\n"; \
		printf "$(G)   Auth:      http://localhost:$$LIVE_PORT/auth/v1/$(R)\n"; \
		printf "$(G)$(R)\n"; \
		printf "$(G)   Staff login:  sophie.laurent@savanna-zoo.com$(R)\n"; \
		printf "$(G)   Password:     $(ZOO_PASS)$(R)\n"; \
		printf "$(G)$(R)\n"; \
		printf "$(C)   Logs:  make logs          (both)$(R)\n"; \
		printf "$(C)          make logs-baas     (BaaS only)$(R)\n"; \
		printf "$(C)          make logs-front    (frontend only)$(R)\n"; \
		printf "$(C)   Stop:  make turn-off$(R)\n"; \
		printf "$(G)═══════════════════════════════════════════$(R)\n"

# ── make turn-off — shut down everything ──────────────────────
turn-off:
	@printf "$(Y)▸ Shutting everything down …$(R)\n"
	@# Stop Vite frontend (pkill + PID file cleanup)
	@KILLED=0; \
	if [ -f "$(FRONT_PID)" ]; then \
		PID=$$(cat $(FRONT_PID)); \
		pkill -P $$PID 2>/dev/null || true; \
		kill $$PID 2>/dev/null && KILLED=1 || true; \
		rm -f $(FRONT_PID); \
	fi; \
	pkill -f "[p]npm dev" 2>/dev/null && KILLED=1 || true; \
	pkill -f "[v]ite.*$(FRONT_DIR)" 2>/dev/null && KILLED=1 || true; \
	if [ "$$KILLED" = "1" ]; then \
		printf "$(G)  ✓ Frontend stopped$(R)\n"; \
	else \
		printf "$(C)  · No frontend process found$(R)\n"; \
	fi
	@# Stop BaaS log tailing (saved PID)
	@if [ -f "$(BAAS_LOG_PID)" ]; then \
		LPID=$$(cat $(BAAS_LOG_PID)); \
		kill $$LPID 2>/dev/null || true; \
		rm -f $(BAAS_LOG_PID); \
	fi
	@# Stop zoo frontend container (nginx)
	@$(DC_ZOO) down 2>/dev/null || true
	@printf "$(G)  ✓ Zoo container stopped$(R)\n"
	@# Stop BaaS infrastructure
	@$(DC_ROOT) down 2>/dev/null || true
	@printf "$(G)  ✓ BaaS infrastructure stopped$(R)\n"
	@# Cleanup log directory
	@rm -rf $(LOG_DIR)
	@printf "$(G)═══════════════════════════════════════════$(R)\n"
	@printf "$(G) ✓ Everything is off.$(R)\n"
	@printf "$(G)═══════════════════════════════════════════$(R)\n"

# ══════════════════════════════════════════════════════════════

# ── Seed / reset database ────────────────────────────────────
seed:
	@printf "$(Y)▸ Seeding zoo database …$(R)\n"
	@unset KONG_URL; ZOO_PASSWORD="$(ZOO_PASS)" bash $(INFRA_DIR)/init.sh
	@printf "$(G)  ✓ Database seeded$(R)\n"

reset:
	@printf "$(Y)▸ Resetting zoo database …$(R)\n"
	@unset KONG_URL; FORCE=1 ZOO_PASSWORD="$(ZOO_PASS)" bash $(INFRA_DIR)/init.sh
	@printf "$(G)  ✓ Database reset$(R)\n"

# ── Build the frontend ───────────────────────────────────────
build:
	@printf "$(Y)▸ Building frontend …$(R)\n"
	cd $(FRONT_DIR) && pnpm install --frozen-lockfile 2>/dev/null || cd $(FRONT_DIR) && pnpm install
	cd $(FRONT_DIR) && pnpm build
	@printf "$(G)  ✓ Frontend built → front/dist/$(R)\n"

# ── Serve via Docker (nginx) ─────────────────────────────────
serve:
	@if [ ! -d "$(FRONT_DIR)/dist" ]; then \
		printf "$(R)Error: front/dist/ missing. Run 'make build' first.$(R)\n"; \
		exit 1; \
	fi
	@printf "$(Y)▸ Starting zoo frontend container …$(R)\n"
	$(DC_ZOO) up -d
	@printf "$(G)  ✓ Frontend served at http://localhost:5180$(R)\n"

# ── Dev mode (alias for dev-all) ──────────────────────────────
dev: dev-all

# ── Housekeeping ─────────────────────────────────────────────
down:
	$(DC_ZOO) down

clean: down
	rm -rf $(FRONT_DIR)/dist $(LOG_DIR)
	@printf "$(G)  ✓ Cleaned$(R)\n"

logs:
	@if [ -f "$(BAAS_LOG)" ] && [ -f "$(FRONT_LOG)" ]; then \
		tail -f $(BAAS_LOG) $(FRONT_LOG); \
	else \
		printf "$(C)No background logs found. Use 'make dev-all' first.$(R)\n"; \
		printf "$(C)Falling back to docker logs …$(R)\n"; \
		$(DC_ROOT) logs -f --tail=50; \
	fi

logs-baas:
	@if [ -f "$(BAAS_LOG)" ]; then \
		tail -f $(BAAS_LOG); \
	else \
		$(DC_ROOT) logs -f --tail=50; \
	fi

logs-front:
	@if [ -f "$(FRONT_LOG)" ]; then \
		tail -f $(FRONT_LOG); \
	else \
		printf "$(C)No frontend log found. Start with 'make dev-all' or 'make front'.$(R)\n"; \
	fi

status:
	@printf "$(C)── BaaS Stack ──────────────────────────────$(R)\n"
	@$(DC_ROOT) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(not running)"
	@printf "\n$(C)── Zoo Frontend ────────────────────────────$(R)\n"
	@$(DC_ZOO) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(not running)"

# ── Help ─────────────────────────────────────────────────────
help:
	@printf "$(C)Savanna Park Zoo — Makefile targets$(R)\n\n"
	@printf "  $(G)make dev-all$(R)     Start BaaS + frontend in background\n"
	@printf "  $(G)make baas$(R)        Start only the BaaS backend (+ logs)\n"
	@printf "  $(G)make front$(R)       Start only the Vite frontend\n"
	@printf "  $(G)make turn-off$(R)    Shut down everything\n"
	@printf "\n"
	@printf "  $(G)make all$(R)         Full pipeline: build → BaaS → seed → serve\n"
	@printf "  $(G)make build$(R)       Build the frontend to front/dist/\n"
	@printf "  $(G)make baas-up$(R)     Start BaaS infrastructure (no logs)\n"
	@printf "  $(G)make seed$(R)        Seed zoo data into the BaaS\n"
	@printf "  $(G)make reset$(R)       Drop + reseed zoo data\n"
	@printf "  $(G)make serve$(R)       Serve built frontend via Docker\n"
	@printf "  $(G)make down$(R)        Stop zoo frontend container\n"
	@printf "  $(G)make clean$(R)       Remove dist/ and stop container\n"
	@printf "  $(G)make logs$(R)        Tail all logs (BaaS + frontend)\n"
	@printf "  $(G)make logs-baas$(R)   Tail BaaS logs only\n"
	@printf "  $(G)make logs-front$(R)  Tail frontend logs only\n"
	@printf "  $(G)make status$(R)      Show running containers\n"
	@printf "  $(G)make help$(R)        Show this help\n"
	@printf "\n$(Y)Environment:$(R)\n"
	@printf "  KONG_URL=$(KONG_URL)  API_KEY=$(API_KEY)\n"
	@printf "  ZOO_PASS=$(ZOO_PASS)\n"
