##@ Testing

.PHONY: test-unit test-e2e test-all coverage test-postman

test-unit: ## Run unit tests
	@$(SCRIPTS_PATH)/test/unit.sh

test-e2e: ## Run E2E tests
	@$(SCRIPTS_PATH)/test/e2e.sh

test-all: ## Run all tests (unit + E2E) with full report
	@$(SCRIPTS_PATH)/test/all.sh

coverage: ## Run tests and generate coverage report
	@$(SCRIPTS_PATH)/test/coverage.sh

test-postman: ## Run Postman auth collection against local backend
	@$(SCRIPTS_PATH)/test/postman-cli.sh run-local $(BACKEND_PATH)/postman/auth.json
