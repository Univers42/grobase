##@ Backend Tools

.PHONY: debug services install

debug: ## Start backend with Node.js inspector (--inspect)
	@$(SCRIPTS_PATH)/backend/debug.sh

services: ## Print a summary of registered backend services
	@$(SCRIPTS_PATH)/backend/services.sh

install: ## Install all npm dependencies (Back + View)
	@$(SCRIPTS_PATH)/utils/install.sh
