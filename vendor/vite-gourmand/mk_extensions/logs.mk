##@ Logs

.PHONY: logs docker-service-logs docker-check

logs: ## View server logs (auto-detects Docker or local mode)
	@if $(DOCKER_COMPOSE) ps 2>/dev/null | grep -q "dev.*Up"; then \
		printf '=== Backend (container) ===\n'; \
		$(DOCKER_COMPOSE) exec dev tail -100 /tmp/backend.log 2>/dev/null || printf '(no log yet)\n'; \
		printf '\n=== Frontend (container) ===\n'; \
		$(DOCKER_COMPOSE) exec dev tail -100 /tmp/frontend.log 2>/dev/null || printf '(no log yet)\n'; \
	else \
		printf '=== Backend ===\n'; \
		tail -50 /tmp/vg-backend.log 2>/dev/null || printf '(no log yet)\n'; \
		printf '\n=== Frontend ===\n'; \
		tail -50 /tmp/vg-frontend.log 2>/dev/null || printf '(no log yet)\n'; \
	fi

docker-service-logs: ## Stream container logs (SERVICE=name for specific container, TAIL=N)
	@SERVICE="$(SERVICE)" TAIL="$(TAIL)" $(SCRIPTS_PATH)/docker/logs.sh

docker-check: ## Run Docker infrastructure health check
	@$(SCRIPTS_PATH)/docker/check_docker.sh
