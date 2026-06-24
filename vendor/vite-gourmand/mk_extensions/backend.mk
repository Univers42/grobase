##@ Backend Development

.PHONY: dev build lint compile format

dev: ## Start backend in development mode (watch, host)
	@$(SCRIPTS_PATH)/backend/dev.sh

build: ## Build backend for production
	@$(SCRIPTS_PATH)/backend/build.sh

lint: ## Run ESLint on backend (FIX=1 for auto-fix)
	@FIX="$(FIX)" $(SCRIPTS_PATH)/backend/lint.sh

compile: ## TypeScript compile check on backend (no emit)
	@$(SCRIPTS_PATH)/backend/compile.sh

format: ## Format backend code with Prettier (CHECK=1 to check only)
	@CHECK="$(CHECK)" $(SCRIPTS_PATH)/backend/format.sh
