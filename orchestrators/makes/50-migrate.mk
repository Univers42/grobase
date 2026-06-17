# ========================================================================== #
##@ Migrations & data
# ========================================================================== #
migrate: ## Apply pending PostgreSQL migrations
	@set -e; for f in $$(ls -1 scripts/migrations/postgresql/*.sql 2>/dev/null | sort); do \
		echo "  Applying: $$f"; sed '/^#/d' "$$f" | $(DC) exec -T postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f -; \
	done; echo -e "$(_G)✓ PostgreSQL migrations applied$(_0)"

migrate-mongo: ## Apply MongoDB migrations
	@for f in $$(ls -1 scripts/migrations/mongodb/*.js 2>/dev/null | sort); do \
		echo "  Applying: $$f"; $(DC) --profile data-plane exec -T mongo mongosh mini_baas < "$$f"; done
	@echo -e "$(_G)✓ MongoDB migrations applied$(_0)"

migrate-mysql: ## Apply MySQL migrations
	@set -e; for f in $$(ls -1 scripts/migrations/mysql/*.sql 2>/dev/null | sort); do \
		echo "  Applying: $$f"; $(DC) --profile data-plane exec -T mysql sh -ec 'mysql -u"$${MYSQL_USER:-mini_baas}" -p"$${MYSQL_PASSWORD:-mini_baas_pw}" "$${MYSQL_DATABASE:-mini_baas}"' < "$$f"; done
	@echo -e "$(_G)✓ MySQL migrations applied$(_0)"

migrate-all: migrate migrate-mongo migrate-mysql ## Apply PG + Mongo + MySQL migrations

migrate-status: ## Show applied migration versions
	@$(DC) exec -T postgres psql -U postgres -d postgres -c "SELECT version, name, applied_at FROM schema_migrations ORDER BY version;" 2>/dev/null || echo "  No migrations table yet — run make migrate."

seed-mongo: _require-compose ## Seed MongoDB demo data
	@bash scripts/seed/seed-mongo.sh

seed-live-demo: _require-compose ## Seed the live-database demo across pg+mysql+mongo (owned by the osionos app key; RESEED=1 wipes first)
	@bash scripts/seed/seed-live-demo.sh

