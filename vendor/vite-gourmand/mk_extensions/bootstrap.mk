##@ Bootstrap (local, host Node.js)

.PHONY: local-bootstrap step-1-secrets step-2-install step-3-compile secrets-force

local-bootstrap: ## Run the full local bootstrap sequence (secrets, install, compile, start)
	@printf '\n-- VITE GOURMAND - Local Development (host Node.js) --\n\n'
	@printf 'This mode requires Node.js and npm installed on your host.\n'
	@printf 'For containerized development use: make\n\n'
	@$(MAKE) --no-print-directory step-1-secrets
	@$(MAKE) --no-print-directory step-2-install
	@$(MAKE) --no-print-directory step-3-compile
	@$(MAKE) --no-print-directory step-4-start
	@$(MAKE) --no-print-directory summary

step-1-secrets: ## Fetch Back/.env from Bitwarden (interactive)
	@$(SCRIPTS_PATH)/docker/bw-fetch-env.sh
	@if [ ! -f $(BACKEND_PATH)/.env ]; then \
		printf '\nBack/.env is required to continue.\n'; \
		printf 'Re-run: make step-1-secrets\n'; \
		exit 1; \
	fi
	@printf '\nBack/.env is ready.\n'

step-2-install: ## Install all npm dependencies and generate Prisma client
	@printf '\n[1/3] Backend dependencies...\n'
	@cd $(BACKEND_PATH) && npm install
	@printf '\n[2/3] Frontend dependencies...\n'
	@cd $(FRONTEND_PATH) && npm install
	@printf '\n[3/3] Generating Prisma client...\n'
	@cd $(BACKEND_PATH) && npx prisma generate
	@printf '\nDependencies installed.\n'

step-3-compile: ## TypeScript compile check for backend and frontend (no emit)
	@printf 'Checking Backend...\n'
	@cd $(BACKEND_PATH) && npx tsc --noEmit || { printf 'TypeScript errors in Backend\n'; exit 1; }
	@printf 'Checking Frontend...\n'
	@cd $(FRONTEND_PATH) && npx tsc --noEmit || { printf 'TypeScript errors in Frontend\n'; exit 1; }
	@printf 'No compilation errors.\n'

secrets-force: ## Force re-fetch Back/.env from Bitwarden (overwrites existing)
	@rm -f $(BACKEND_PATH)/.env
	@$(MAKE) --no-print-directory step-1-secrets
