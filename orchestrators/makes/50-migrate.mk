# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    50-migrate.mk                                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:51 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 22:59:53 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

##@ Migrations, seeds & the vendor playground apps
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

# SCHEMA-QUALIFIED on purpose: GoTrue keeps its OWN auth.schema_migrations (one
# varchar column), and an unqualified name resolves to that one first — so this
# printed "No migrations table yet" on a fully migrated stack, because selecting
# name/applied_at from GoTrue's table errors and the || hid it. Errors are shown now:
# a status command that masks its own failure is worse than one that prints nothing.
migrate-status: ## Show applied migration versions
	@$(DC) exec -T postgres psql -U postgres -d postgres \
		-c "SELECT version, name, applied_at FROM public.schema_migrations ORDER BY version;" \
		|| echo "  Could not read public.schema_migrations (is postgres up? has make migrate run?)"

seed-mongo: _require-compose ## Seed MongoDB demo data
	@bash scripts/seed/seed-mongo.sh

seed-live-demo: _require-compose ## Seed the live-database demo across pg+mysql+mongo (owned by the osionos app key; RESEED=1 wipes first)
	@bash scripts/seed/seed-live-demo.sh

GOURMAND_PORT ?= 5180

RED_TETRIS_PORT ?= 5178

MOVIEVERSE_PORT ?= 5173

HYPERTUBE_PORT     ?= 5176
HT_CATALOG_TARGET  ?= 400