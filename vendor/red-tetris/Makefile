# ==============================================================================
# Red Tetris — Makefile
# ==============================================================================

.PHONY: all run dev build test clean fclean re install stop help

PORT     := 3004
PID_FILE := .server.pid
BROWSER  := xdg-open  # Use 'open' on macOS

# Default target
all: run

# ─── Production run (build + start server + open browser) ────────────────────
run: build
	@echo "\033[1;32m▶  Starting server on http://localhost:$(PORT)\033[0m"
	@node src/server/index.js & echo $$! > $(PID_FILE)
	@sleep 1
	@$(BROWSER) http://localhost:$(PORT) 2>/dev/null || true
	@echo "\033[1;36m✔  Server PID $$(cat $(PID_FILE)) — run 'make stop' to shut down\033[0m"
	@tail -f /dev/null

# ─── Development mode (webpack HMR on :3000, server on :3004) ────────────────
dev: node_modules
	@echo "\033[1;33m▶  Dev server → webpack :3000  |  API :3004\033[0m"
	@node src/server/index.js & echo $$! > $(PID_FILE)
	@npm run dev:client

# ─── Production build only ───────────────────────────────────────────────────
build: node_modules
	@echo "\033[1;34m▶  Building production bundle…\033[0m"
	@npm run build
	@echo "\033[1;32m✔  Build complete → dist/\033[0m"

# ─── Tests ───────────────────────────────────────────────────────────────────
test: node_modules
	@echo "\033[1;34m▶  Running test suite…\033[0m"
	@npm test

test-watch: node_modules
	@npm run test:watch

# ─── Install dependencies ────────────────────────────────────────────────────
install: node_modules

node_modules: package.json
	@echo "\033[1;34m▶  Installing dependencies…\033[0m"
	@npm install
	@touch node_modules

# ─── Stop background server ──────────────────────────────────────────────────
stop:
	@if [ -f $(PID_FILE) ]; then \
		PID=$$(cat $(PID_FILE)); \
		kill $$PID 2>/dev/null && echo "\033[1;31m■  Server (PID $$PID) stopped\033[0m" \
		|| echo "\033[1;33m⚠  Process $$PID not found (already stopped?)\033[0m"; \
		rm -f $(PID_FILE); \
	else \
		echo "\033[1;33m⚠  No PID file found — killing any node server on port $(PORT)\033[0m"; \
		lsof -ti tcp:$(PORT) | xargs kill 2>/dev/null || true; \
	fi

# ─── Remove build artefacts & caches ─────────────────────────────────────────
clean:
	@echo "\033[1;31m▶  Cleaning build output and caches…\033[0m"
	@rm -rf dist/ node_modules/.cache $(PID_FILE)
	@echo "\033[1;32m✔  Clean done\033[0m"

# ─── Full clean (includes node_modules) ──────────────────────────────────────
fclean: clean
	@echo "\033[1;31m▶  Removing node_modules…\033[0m"
	@rm -rf node_modules/
	@echo "\033[1;32m✔  Full clean done\033[0m"

# ─── Rebuild from scratch ────────────────────────────────────────────────────
re: fclean install build

# ─── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "\033[1;37mRed Tetris — available targets\033[0m"
	@echo ""
	@echo "  \033[1;32mmake run\033[0m          Build + start server + open browser (http://localhost:$(PORT))"
	@echo "  \033[1;33mmake dev\033[0m          Dev mode: webpack HMR on :3000, API on :3004"
	@echo "  \033[1;34mmake build\033[0m        Production webpack build only"
	@echo "  \033[1;34mmake test\033[0m         Run full test suite with coverage"
	@echo "  \033[1;34mmake test-watch\033[0m   Run tests in watch mode"
	@echo "  \033[1;34mmake install\033[0m      Install npm dependencies"
	@echo "  \033[1;31mmake stop\033[0m         Kill the background server"
	@echo "  \033[1;31mmake clean\033[0m        Remove dist/ and caches"
	@echo "  \033[1;31mmake fclean\033[0m       Remove dist/, caches, and node_modules"
	@echo "  \033[1;31mmake re\033[0m           Full rebuild from scratch"
	@echo ""
