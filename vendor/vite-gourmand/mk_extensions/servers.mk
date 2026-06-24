##@ Local Servers (host Node.js)

.PHONY: step-4-start turn-on turn-off kill-backend kill-frontend

step-4-start: ## Start backend and frontend dev servers on host
	@-fuser -k $(BACKEND_PORT)/tcp 2>/dev/null || true
	@-fuser -k $(FRONTEND_PORT)/tcp 2>/dev/null || true
	@rm -f $(BACKEND_PID) $(FRONTEND_PID)
	@sleep 1
	@printf 'Starting Backend (NestJS) on port %s...\n' $(BACKEND_PORT)
	@cd $(BACKEND_PATH) && nohup npm run start:dev > /tmp/vg-backend.log 2>&1 & echo $$! > $(CURDIR)/$(BACKEND_PID)
	@printf '  PID: %s\n' "$$(cat $(CURDIR)/$(BACKEND_PID))"
	@printf 'Starting Frontend (Vite) on port %s...\n' $(FRONTEND_PORT)
	@cd $(FRONTEND_PATH) && nohup npm run dev > /tmp/vg-frontend.log 2>&1 & echo $$! > $(CURDIR)/$(FRONTEND_PID)
	@printf '  PID: %s\n' "$$(cat $(CURDIR)/$(FRONTEND_PID))"
	@sleep 5
	@printf 'Servers started.\n'

turn-on: ## Start local servers (assumes deps installed and .env present)
	@if [ ! -f $(BACKEND_PATH)/.env ]; then \
		printf 'Back/.env not found. Run make first.\n'; exit 1; \
	fi
	@$(MAKE) --no-print-directory step-4-start
	@printf '\n  Frontend -> http://localhost:%s\n' $(FRONTEND_PORT)
	@printf '  Backend  -> http://localhost:%s/api\n\n' $(BACKEND_PORT)

turn-off: ## Stop all local dev servers and clean up PID/log files
	@printf 'Stopping frontend...\n'
	@if [ -f $(FRONTEND_PID) ]; then kill $$(cat $(FRONTEND_PID)) 2>/dev/null || true; rm -f $(FRONTEND_PID); fi
	@-fuser -k $(FRONTEND_PORT)/tcp 2>/dev/null || true
	@printf 'Stopping backend...\n'
	@if [ -f $(BACKEND_PID) ]; then kill $$(cat $(BACKEND_PID)) 2>/dev/null || true; rm -f $(BACKEND_PID); fi
	@-fuser -k $(BACKEND_PORT)/tcp 2>/dev/null || true
	@rm -f /tmp/vg-backend.log /tmp/vg-frontend.log 2>/dev/null || true
	@printf 'Servers stopped.\n'

kill-backend: ## Stop backend dev server and free port 3000
	@if [ -f $(BACKEND_PID) ]; then kill $$(cat $(BACKEND_PID)) 2>/dev/null || true; rm -f $(BACKEND_PID); fi
	@-fuser -k $(BACKEND_PORT)/tcp 2>/dev/null || true
	@printf 'Backend stopped (port %s freed).\n' $(BACKEND_PORT)

kill-frontend: ## Stop frontend dev server and free port 5173
	@if [ -f $(FRONTEND_PID) ]; then kill $$(cat $(FRONTEND_PID)) 2>/dev/null || true; rm -f $(FRONTEND_PID); fi
	@-fuser -k $(FRONTEND_PORT)/tcp 2>/dev/null || true
	@printf 'Frontend stopped (port %s freed).\n' $(FRONTEND_PORT)
