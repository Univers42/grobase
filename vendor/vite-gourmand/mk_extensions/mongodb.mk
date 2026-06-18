##@ MongoDB Atlas

.PHONY: mongodb-test mongodb-init mongodb-reset mongodb-cleanup mongodb-stats

mongodb-test: ## Test MongoDB Atlas connection
	@$(SCRIPTS_PATH)/db/mongodb-analytics.sh test

mongodb-init: ## Initialize MongoDB collections and indexes
	@$(SCRIPTS_PATH)/db/mongodb-analytics.sh init

mongodb-reset: ## Drop and reinitialize MongoDB analytics data - DESTRUCTIVE
	@$(SCRIPTS_PATH)/db/mongodb-analytics.sh reset

mongodb-cleanup: ## Remove stale documents based on retention policy
	@$(SCRIPTS_PATH)/db/mongodb-analytics.sh cleanup

mongodb-stats: ## Show MongoDB collection sizes and storage usage
	@$(SCRIPTS_PATH)/db/mongodb-analytics.sh stats
