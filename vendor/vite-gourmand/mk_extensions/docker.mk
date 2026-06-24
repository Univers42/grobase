##@ Docker Infrastructure

.PHONY: up down ps wait docker-containers-restart

up: ## Start all Docker containers (production/tools profiles)
	@$(SCRIPTS_PATH)/docker/up.sh

down: ## Stop all Docker containers
	@$(SCRIPTS_PATH)/docker/down.sh

ps: ## Show status of all project containers
	@$(SCRIPTS_PATH)/docker/ps.sh

wait: ## Wait until PostgreSQL and MongoDB containers are ready
	@printf 'Waiting for PostgreSQL...\n'
	@until docker exec vite-gourmand-db-1 pg_isready -U postgres 2>/dev/null; do sleep 1; done
	@printf 'Waiting for MongoDB...\n'
	@until docker exec vite-gourmand-mongo-1 mongosh --eval "db.adminCommand('ping')" >/dev/null 2>&1; do sleep 1; done
	@printf 'Databases ready.\n'

docker-containers-restart: ## Restart production and tools containers
	@$(SCRIPTS_PATH)/docker/restart.sh
