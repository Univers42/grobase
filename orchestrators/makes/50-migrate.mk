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

GOURMAND_PORT ?= 5180

# The data plane caches a mount's shared_resources/owner-scoping at registration;
# a fresh provision needs a data-plane-router restart before the scoping is live.
gourmand-verify: _require-compose ## vite-gourmand: provision + prove the BaaS end-to-end (DB/auth/owner-scope/triggers) via the m149 gate
	@DATA_PLANE_PER_TABLE_ISOLATION=1 DATA_PLANE_ADMIN_BYPASS=1 $(MAKE) --no-print-directory up
	@bash scripts/seed/gourmand-baas.sh
	@docker restart mini-baas-data-plane-router-rust >/dev/null 2>&1 || true
	@bash scripts/verify/m149-gourmand-baas.sh
	@echo -e "$(_G)✓ vite-gourmand BaaS verified (seed + m149 gate)$(_0)"

gourmand: gourmand-verify ## vite-gourmand: full end-to-end — verify, then build the SPA + serve it (http://localhost:5180)
	@docker run --rm -v "$(CURDIR)/vendor/vite-gourmand/View":/app -w /app node:20-alpine sh -c 'npm ci && npm run build'
	@GOURMAND_PORT=$(GOURMAND_PORT) $(DC) --profile gourmand up -d --no-deps gourmand
	@echo -e "$(_G)✓ vite-gourmand live → http://localhost:$(GOURMAND_PORT)$(_0)"
	@$(MAKE) --no-print-directory gourmand-creds

gourmand-creds: ## Print the seeded vite-gourmand logins (persisted in .gourmand-baas.env)
	@[ -f .gourmand-baas.env ] || { echo -e "$(_Y)no .gourmand-baas.env yet — run 'make gourmand-verify' first$(_0)"; exit 0; }
	@ae="$$(sed -n 's/^VG_ADMIN_EMAIL=//p' .gourmand-baas.env)"; ap="$$(sed -n 's/^VG_ADMIN_PASSWORD=//p' .gourmand-baas.env)"; \
		ce="$$(sed -n 's/^VG_CLIENT_EMAIL=//p' .gourmand-baas.env)"; cp="$$(sed -n 's/^VG_CLIENT_PASSWORD=//p' .gourmand-baas.env)"; \
		echo -e "$(_W)vite-gourmand logins$(_0)  (saved in .gourmand-baas.env)"; \
		echo -e "  URL       $(_C)http://localhost:$(GOURMAND_PORT)$(_0)"; \
		echo -e "  admin     $(_G)$$ae$(_0) / $(_G)$$ap$(_0)"; \
		echo -e "  customer  $$ce / $$cp"

RED_TETRIS_PORT ?= 5178

# red-tetris: the 42 Tetris re-platformed ENTIRELY onto Grobase (auth + data +
# the multiplayer realtime bus). Brings up the maximal `tetris` edition, provisions
# the contract (DB + mounts + seed), builds the SPA, and serves it same-origin.
red-tetris-provision: _require-compose ## red-tetris: bring up EDITION=tetris + provision the contract (DB/mounts/seed)
	@FUNCTIONS_CRON_ENABLED=1 $(MAKE) --no-print-directory up EDITION=tetris
	@bash scripts/provision-contract.sh infra/config/contracts/red-tetris.json
	@docker restart mini-baas-data-plane-router-rust >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ red-tetris contract provisioned$(_0)"

red-tetris: red-tetris-provision ## red-tetris: full end-to-end — provision, build the SPA, serve it (http://localhost:5178)
	@docker run --rm -v "$(CURDIR)/vendor/red-tetris":/app -w /app node:20-alpine sh -c 'npm ci --silent && npm run build'
	@RED_TETRIS_PORT=$(RED_TETRIS_PORT) $(DC) --profile red-tetris up -d --no-deps red-tetris
	@echo -e "$(_G)✓ red-tetris live → http://localhost:$(RED_TETRIS_PORT)$(_0)"
	@echo -e "  demo logins: $(_C)alice@tetris.local$(_0) … heidi@tetris.local  /  $(_W)Tetris#2026$(_0)"
	@RED_TETRIS_PORT=$(RED_TETRIS_PORT) sh scripts/ops/red-tetris-lan.sh || true

red-tetris-lan: ## red-tetris: discover this host's LAN address so a 2nd computer on the same Wi-Fi can join (writes build/red-tetris-lan.env)
	@RED_TETRIS_PORT=$(RED_TETRIS_PORT) sh scripts/ops/red-tetris-lan.sh
