##@ Deployment

.PHONY: deploy-fly deploy-check deploy-status deploy-logs deploy-certs deploy-fly-shell deploy-safe

deploy-fly: ## Deploy backend to Fly.io
	@$(SCRIPTS_PATH)/deploy/fly.sh

deploy-check: ## Run pre-deployment checks (compile, tests, env)
	@$(SCRIPTS_PATH)/deploy/check.sh

deploy-status: ## Show current Fly.io application status
	@$(SCRIPTS_PATH)/deploy/status.sh

deploy-logs: ## Stream live Fly.io application logs
	@$(SCRIPTS_PATH)/deploy/logs.sh

deploy-certs: ## Inspect/request Fly managed certificates (CREATE_CERTS=true to create)
	@CREATE_CERTS="$(CREATE_CERTS)" HOSTS="$(HOSTS)" $(SCRIPTS_PATH)/deploy/fly-certificates.sh

deploy-fly-shell: ## Open a shell in the Dockerized Fly CLI service
	@if [ -f .env.production ]; then \
		$(DOCKER_COMPOSE) --env-file .env.production --profile tools run --rm fly; \
	else \
		$(DOCKER_COMPOSE) --profile tools run --rm fly; \
	fi

deploy-safe: deploy-check deploy-fly ## Run pre-checks then deploy to Fly.io
