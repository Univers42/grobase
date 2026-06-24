##@ Docker Dev Container

.PHONY: docker-build-dev docker-bootstrap docker-shell docker-stop docker-restart

docker-build-dev: ## Build the development Docker image (Node.js 22 Alpine)
	@docker info >/dev/null 2>&1 || { \
		printf 'Cannot connect to Docker daemon.\n'; \
		printf 'Fix: sudo usermod -aG docker $$USER && newgrp docker\n'; \
		printf 'Or if Docker is not running: sudo systemctl start docker\n'; \
		exit 1; \
	}
	@$(DOCKER_COMPOSE) --profile dev build dev 2>&1
	@printf 'Development container image built.\n'

docker-bootstrap: ## Full containerized bootstrap: build image, fetch secrets, install, compile, start
	@$(MAKE) --no-print-directory docker-build-dev
	@$(MAKE) --no-print-directory step-1-secrets
	@$(DOCKER_COMPOSE) --profile dev up -d dev
	@sleep 3
	@printf '[1/3] Backend dependencies (inside container)...\n'
	@$(DOCKER_COMPOSE) exec dev sh -c "cd /app/Back && npm install --loglevel=error"
	@printf '[2/3] Frontend dependencies (inside container)...\n'
	@$(DOCKER_COMPOSE) exec dev sh -c "cd /app/View && npm install --loglevel=error"
	@printf '[3/3] Generating Prisma client...\n'
	@$(DOCKER_COMPOSE) exec dev sh -c "rm -rf /app/Back/generated/prisma 2>/dev/null || true"
	@$(DOCKER_COMPOSE) exec dev sh -c "cd /app/Back && npx prisma generate"
	@printf 'Checking TypeScript compilation...\n'
	@$(DOCKER_COMPOSE) exec dev sh -c "cd /app/Back && npx tsc --noEmit"
	@$(DOCKER_COMPOSE) exec dev sh -c "cd /app/View && npx tsc --noEmit"
	@printf 'Starting Backend server...\n'
	@$(DOCKER_COMPOSE) exec -d dev sh -c "cd /app/Back && npm run start:dev > /tmp/backend.log 2>&1"
	@sleep 3
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		if $(DOCKER_COMPOSE) exec dev sh -c "curl -s http://localhost:3000/api/site-info > /dev/null 2>&1"; then \
			printf 'Backend ready.\n'; break; \
		fi; \
		printf '  Attempt %s/10 - waiting...\n' $$i; sleep 2; \
	done
	@printf 'Starting Frontend server...\n'
	@$(DOCKER_COMPOSE) exec -d dev sh -c "cd /app/View && npm run dev -- --host 0.0.0.0 > /tmp/frontend.log 2>&1"
	@sleep 3
	@$(MAKE) --no-print-directory summary

docker-shell: ## Open an interactive shell inside the dev container
	@$(DOCKER_COMPOSE) --profile dev exec dev /bin/bash || \
		$(DOCKER_COMPOSE) --profile dev run --rm dev /bin/bash

docker-stop: ## Stop and remove the development container
	@printf 'Stopping development container...\n'
	@$(DOCKER_COMPOSE) --profile dev down
	@printf 'Development container stopped.\n'

docker-restart: ## Restart the dev servers inside the running container
	@-$(DOCKER_COMPOSE) exec dev pkill -f "nest start" 2>/dev/null || true
	@-$(DOCKER_COMPOSE) exec dev pkill -f "vite" 2>/dev/null || true
	@sleep 2
	@$(DOCKER_COMPOSE) exec -d dev sh -c "cd /app/Back && npm run start:dev > /tmp/backend.log 2>&1"
	@$(DOCKER_COMPOSE) exec -d dev sh -c "cd /app/View && npm run dev -- --host 0.0.0.0 > /tmp/frontend.log 2>&1"
	@sleep 3
	@printf 'Servers restarted.\n'
	@printf '  Frontend -> http://localhost:%s\n' $(FRONTEND_PORT)
	@printf '  Backend  -> http://localhost:%s/api\n' $(BACKEND_PORT)
