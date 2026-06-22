# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    80-ops.mk                                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:35 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/22 12:42:25 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

preflight: ## Run pre-deployment checks
	@bash scripts/ci/preflight-check.sh
hooks: ## Activate git hooks
	@if [ -d .git ]; then git config --local core.hooksPath $(HOOKS_DIR); chmod +x $(HOOKS_DIR)/* 2>/dev/null || true; echo -e "  $(_G)✓$(_0) hooks → $(HOOKS_DIR)"; else echo "  • not a git repo"; fi
update: ## Update git submodules
	@git submodule update --remote --merge && echo -e "$(_G)✓ Submodules updated$(_0)"


backup-now: ## Take a one-off Postgres backup right now (pg-backup `once` → MinIO)
	@echo -e "$(_B)Running an on-demand backup (pg-backup once)…$(_0)"
	@docker compose --profile backups run --rm pg-backup once \
		&& echo -e "$(_G)✓ backup complete — under the configured MinIO bucket$(_0)"

restore-verify: ## Prove a backup restores (dump→drop→restore→checksum, scratch DB; tenant data untouched)
	@bash scripts/verify/m47-backup-restore.sh

cloud-flags-print: ## Print the managed-cloud flag manifest (B7.1 single flip point — OPT-IN, no behaviour)
	@cat infra/config/cloud/flags.env.example
	@echo ""
	@echo -e "$(_D)Opt-in: the default stack ignores this manifest (all flags default OFF in code = byte-parity).$(_0)"
	@echo -e "$(_D)Promotion ladder (staging→canary→prod): infra/config/cloud/README.md$(_0)"

# ── Cloud edition (managed-cloud, all flags ON, mock Stripe) ─────────────────
# The env-only overlay docker-compose.cloud.yml + infra/config/cloud/flags.env.cloud
# layered onto the default compose with the EDITION=prod planes + the `cloud`
# profile (stripe-mock). OPT-IN: a non-cloud `make up` never passes these `-f`s,
# so the default stack stays byte-parity (kernel #5). Design: wiki/cloud-edition-design.md.
CLOUD_FILES     := -f $(COMPOSE_FILE) -f orchestrators/compose/docker-compose.cloud.yml
CLOUD_PROFILES  := --profile control-plane --profile go-control-plane \
                   --profile rust-data-plane --profile adapter-plane \
                   --profile background --profile storage --profile realtime \
                   --profile observability --profile ops --profile backups \
                   --profile cloud

cloud-up: _require-compose _rm-stale ## Boot the FULL managed-cloud stack locally (all cloud flags ON, mock Stripe)
	@echo -e "$(_B)Starting CLOUD edition (all managed-cloud flags ON, mock Stripe) → prod planes + cloud profile$(_0)"
	@eval "$$(bash scripts/ops/resolve-ports.sh 2>/dev/null || true)"; \
	  docker compose $(CLOUD_FILES) $(CLOUD_PROFILES) up -d $(SERVICE)
	@echo -e "$(_G)✓ Cloud edition up (infra/config/cloud/flags.env.cloud layered; stripe-mock in the cloud profile)$(_0)"

cloud-down: _require-compose ## Stop the cloud edition (overlay + cloud profile)
	@docker compose $(CLOUD_FILES) $(CLOUD_PROFILES) down
	@echo -e "$(_G)✓ Cloud edition down$(_0)"

docker-gc: ## Reclaim build cache >1wk + named build-cache volumes (daemon GC can't reach volumes); never touches *-data
	-docker buildx prune -f --filter until=168h
	-docker image prune -f
	-@docker volume ls -q \
		| grep -E 'cargo|target|node_modules|gocache|gomod|go-build|go-mod|modcache|npm-cache|deno-cache|-m2$$|-nm$$|hypertube-cache|vault42-bin' \
		|xargs -r docker volume rm 2>/dev/null
	@docker system df

# ── vault42 + 42ctl as published images (no clone) ───────────────────────────
# vault42-server (the ZK motor) runs from its Docker Hub image, wired to grobase as its
# store via the vault42 contract; 42ctl is its CLI, also run from an image. Override the
# tags with VAULT42_IMAGE / CTL_IMAGE.
VAULT42_IMAGE ?= docker.io/dlesieur/vault42-server:latest
CTL_IMAGE     ?= docker.io/dlesieur/42ctl:latest

vault42-up: _require-compose ## Provision the vault42 contract + run vault42-server (image) wired to grobase as its store
	@bash scripts/provision-contract.sh infra/config/contracts/vault42.json 2>&1 | tail -6
	@VAULT42_IMAGE=$(VAULT42_IMAGE) docker compose --profile vault42 up -d vault42
	@echo -e "  $(_G)✓$(_0) vault42-server up on :$${VAULT42_PORT:-8443} (GrobaseStore → kong). CLI: $(_B)make ctl ARGS=\"org create --slug x --name X\"$(_0)"

vault42-down: ## Stop vault42-server (the vault42 profile)
	@docker compose --profile vault42 down

vault42-logs: ## Follow vault42-server logs
	@docker compose --profile vault42 logs -f vault42

quickstart-vault42: ## One command: bring up grobase deps (EDITION=query) + vault42-server (image)
	@$(MAKE) up EDITION=query
	@$(MAKE) vault42-up

ctl: ## Run 42ctl from its image — make ctl ARGS="org create --slug x --name X" (state in ./.42ctl)
	@mkdir -p .42ctl
	@docker run --rm -it --network mini-baas_mini-baas \
		--user "$$(id -u):$$(id -g)" \
		-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 \
		-v "$(CURDIR)/.42ctl:/cfg" $(CTL_IMAGE) $(ARGS)
