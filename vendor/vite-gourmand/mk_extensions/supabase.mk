##@ Supabase

.PHONY: supabase-setup supabase-deploy supabase-validate supabase-introspect supabase-tables

supabase-setup: ## Interactive Supabase project setup
	@$(SCRIPTS_PATH)/supabase/setup-supabase.sh

supabase-deploy: ## Deploy SQL schemas to Supabase - DESTRUCTIVE
	@$(SCRIPTS_PATH)/supabase/deploy-supabase.sh

supabase-validate: ## Validate SQL schema files before deployment
	@$(SCRIPTS_PATH)/supabase/validate-sql.sh

supabase-introspect: ## Introspect live Supabase schema and regenerate Prisma schema
	@$(SCRIPTS_PATH)/supabase/prisma-introspect.sh

supabase-tables: ## List all public tables on Supabase
	@. $(BACKEND_PATH)/.env && psql "$$DIRECT_URL" -c \
		"SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name;"
