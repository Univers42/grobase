##@ Cleanup

.PHONY: clean docker-fclean fclean re

clean: ## Remove build artifacts (DEEP=1 also removes node_modules)
	@DEEP="$(DEEP)" $(SCRIPTS_PATH)/utils/clean.sh

docker-fclean: ## Stop dev container and remove Docker volumes
	@-$(DOCKER_COMPOSE) --profile dev --profile tools --profile production down 2>/dev/null || true
	@-docker volume rm vite-gourmand_back-node-modules 2>/dev/null || true
	@-docker volume rm vite-gourmand_view-node-modules 2>/dev/null || true
	@-docker volume rm vite-gourmand_npm-cache 2>/dev/null || true
	@-rm -f $(BACKEND_PATH)/.env 2>/dev/null || true
	@printf 'Docker cleanup complete. Run make to start fresh.\n'

fclean: ## Nuclear clean: stop everything, remove all Docker artifacts and local files
	@-$(MAKE) --no-print-directory turn-off 2>/dev/null || true
	@printf '[1/6] Stopping containers...\n'
	@-docker kill $$(docker ps -q --filter "name=vite-gourmand") 2>/dev/null || true
	@-docker kill $$(docker ps -q --filter "name=vite_gourmand") 2>/dev/null || true
	@printf '[2/6] Removing containers...\n'
	@-docker rm -f $$(docker ps -aq --filter "name=vite-gourmand") 2>/dev/null || true
	@-docker rm -f $$(docker ps -aq --filter "name=vite_gourmand") 2>/dev/null || true
	@printf '[3/6] Removing images...\n'
	@-docker rmi -f $$(docker images -q --filter "reference=vite-gourmand*") 2>/dev/null || true
	@-docker images --format '{{.Repository}}:{{.Tag}}' | grep -i vite | grep -i gourmand | xargs -r docker rmi -f 2>/dev/null || true
	@printf '[4/6] Removing volumes...\n'
	@-docker volume rm -f $$(docker volume ls -q | grep -i vite | grep -i gourmand) 2>/dev/null || true
	@printf '[5/6] Pruning build cache...\n'
	@-docker image prune -f 2>/dev/null || true
	@-docker builder prune -f 2>/dev/null || true
	@printf '[6/6] Removing local files...\n'
	@-rm -f $(BACKEND_PATH)/.env 2>/dev/null || true
	@-rm -rf $(BACKEND_PATH)/generated $(BACKEND_PATH)/node_modules $(BACKEND_PATH)/dist $(BACKEND_PATH)/coverage 2>/dev/null || true
	@-rm -rf $(FRONTEND_PATH)/node_modules $(FRONTEND_PATH)/dist $(FRONTEND_PATH)/coverage 2>/dev/null || true
	@-rm -f $(BACKEND_PID) $(FRONTEND_PID) /tmp/vg-backend.log /tmp/vg-frontend.log 2>/dev/null || true
	@printf 'Nuclear clean complete. Run make to bootstrap from scratch.\n'

re: fclean all ## Full rebuild from scratch (fclean then all)
