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

newsletter-broadcast: _require-compose ## Send a newsletter to all CONFIRMED subscribers — server-side ops (SUBJECT= HTML= [TEXT=])
	@SUBJECT="$(SUBJECT)" HTML="$(HTML)" TEXT="$(TEXT)" bash scripts/ops/newsletter-broadcast.sh

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

# ── project-scoped clean + automatic rebuild ─────────────────────────────────
# clean-project erases ONLY this project (compose project `mini-baas`): its containers,
# networks, project images (the grobase planes + the suite motor/CLI/realtime — see
# PROJ_IMG_RE), dangling layers, this suite's build-CACHE volumes (cargo/target/
# node_modules) and the DEFAULT builder's build cache. It NEVER removes *-data/_data
# volumes (Postgres/Mongo/MySQL/… pure data), NEVER touches another project's images,
# volumes, or its OWN buildx builder (e.g. track-binocle-builder keeps its cache), and
# never runs a global `docker system prune`. KEEP_CACHES=1 keeps the build caches for a
# faster rebuild (default removes them — "all the caches").
DATA_VOL_RE := (\-|_)data($$|[-_])|pgdata|keyfile
# This project's images = the grobase planes + the suite's own motor (vault42-server),
# CLI (42ctl) and realtime image — NOT base images (postgres/rust/alpine/mailpit) and
# NOT other apps (pomodoro/hellish), which are kept.
PROJ_IMG_RE := ^(ghcr\.io/univers42/grobase-|mini-baas[-_]|binocle[-_]|dlesieur/(vault42-server|realtime-agnostic|42ctl)(:|$$)|(vault42-server|42ctl|realtime-agnostic):)
clean-project: _require-compose ## Erase THIS project's images/containers/networks/build-caches ONLY — keeps all data volumes + other projects
	@echo -e "$(_Y)$(_W)▶ project clean (mini-baas) — data volumes + other projects PRESERVED$(_0)"
	@echo "  • containers (compose project=mini-baas)…"
	@docker ps -aq --filter label=com.docker.compose.project=mini-baas | xargs -r docker rm -f >/dev/null 2>&1 || true
	@echo "  • networks (compose project=mini-baas)…"
	@docker network ls -q --filter label=com.docker.compose.project=mini-baas | xargs -r docker network rm >/dev/null 2>&1 || true
	@imgs=$$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '$(PROJ_IMG_RE)' || true); \
	  n=$$(printf '%s' "$$imgs" | grep -c . || true); \
	  echo "  • images: $$n project image(s) (grobase-* · vault42-server · realtime-agnostic · 42ctl) — base/other-app images kept…"; \
	  [ -z "$$imgs" ] || echo "$$imgs" | xargs -r docker rmi -f >/dev/null 2>&1 || true
	@docker image prune -f >/dev/null 2>&1 || true
	@if [ -z "$(KEEP_CACHES)" ]; then \
	  echo "  • this suite's BUILD-CACHE volumes (cargo/target/node_modules) — never *-data…"; \
	  docker volume ls -q \
	    | grep -E 'cargo|target|node_modules|gocache|go-?mod|go-build|modcache|npm-cache|deno-cache|-m2$$|-nm$$|hypertube-cache|vault42-bin' \
	    | grep -vE 'track-binocle|$(DATA_VOL_RE)' \
	    | xargs -r docker volume rm >/dev/null 2>&1 || true; \
	  echo "  • build cache: the DEFAULT builder (where this project builds) — dedicated builders (track-binocle/prismatica) keep theirs…"; \
	  docker buildx prune -af >/dev/null 2>&1 || true; docker builder prune -af >/dev/null 2>&1 || true; \
	else echo "  • KEEP_CACHES=1 → build caches kept (faster rebuild)"; fi
	@echo -e "$(_G)✓ clean done — PRESERVED data volumes:$(_0)"; docker volume ls -q | grep -E '$(DATA_VOL_RE)' | sed 's/^/      /'
	@docker system df

fclean-project: ## DANGER: clean-project + WIPE this project's OWN data volumes (mini-baas_*). Needs CONFIRM=1. Never touches other projects, no global prune.
	@vols=$$(docker volume ls -q | grep -E '^mini-baas_' || true); \
	echo -e "$(_Y)$(_W)⚠ fclean = clean-project + PERMANENT DELETE of this project's data volumes (mini-baas_* only):$(_0)"; \
	if [ -n "$$vols" ]; then echo "$$vols" | sed 's/^/    /'; else echo "    (no mini-baas_ data volumes present)"; fi; \
	echo "  (other projects e.g. track-binocle_* + non-prefixed app volumes are NOT touched)"; \
	if [ "$(CONFIRM)" != "1" ]; then \
	  echo -e "$(_Y)Refusing without confirmation — nothing removed. Re-run: make fclean CONFIRM=1$(_0)"; exit 1; fi
	@$(MAKE) --no-print-directory clean-project
	@docker volume ls -q | grep -E '^mini-baas_' | xargs -r docker volume rm >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ this project's data volumes wiped (irreversible) — other projects intact$(_0)"

# ── vault42 + 42ctl as published images (no clone) ───────────────────────────
# vault42-server (the ZK motor) runs from its Docker Hub image, wired to grobase as its
# store via the vault42 contract; 42ctl is its CLI, also run from an image. Override the
# tags with VAULT42_IMAGE / CTL_IMAGE.
VAULT42_IMAGE     ?= docker.io/dlesieur/vault42-server:latest
CTL_IMAGE         ?= docker.io/dlesieur/42ctl:latest
VAULT_ENV_PROJECT ?= grobase

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

# ── 42ctl against the REMOTE fly stack — no clone, no cargo, no local stack ───
# Runs the published image on the DEFAULT bridge (so it reaches vault42.fly.dev),
# auto-writes the profile if absent, persists identity in ~/.config/42ctl, and mounts
# THIS repo as the workdir so `pull` materializes the *.env tree here. Pass the keystore
# passphrase via the FT_PASSPHRASE env (forwarded into the container). E.g. a fresh PC:
#   FT_PASSPHRASE=… make ctl-remote ARGS="keys recover --email you@example.com"
#   FT_PASSPHRASE=… make ctl-remote ARGS="auth login --email you@example.com --tenant grobase-secrets --token <TOKEN>"
#   make ctl-remote ARGS="pull --project grobase --apply"
CTL_CFG_DIR := $(HOME)/.config/42ctl
ctl-remote: ## 42ctl from its image vs the REMOTE fly stack — make ctl-remote ARGS="pull --project grobase --apply"
	@mkdir -p $(CTL_CFG_DIR)
	@[ -f $(CTL_CFG_DIR)/config.json ] || printf '%s\n' '{"current":"default","profiles":{"default":{"server":"https://vault42.fly.dev","authority":"https://grobase-nano.fly.dev","grobase":"https://grobase-stack.fly.dev"}}}' > $(CTL_CFG_DIR)/config.json
	@docker run --rm -it --user "$$(id -u):$$(id -g)" \
		-e FT_CONFIG=/cfg/config.json -e FT_KEYSTORE=/cfg/keystore.v42 -e FT_PASSPHRASE \
		-v "$(CTL_CFG_DIR):/cfg" -v "$(CURDIR):/work" -w /work \
		$(CTL_IMAGE) $(ARGS)

# ── one-shot *.env tree sync to/from vault42 (passphrase read HIDDEN, no prompt-hang) ─
# These wrap the recover→login→push/pull flow so you never fight the interactive
# `passphrase:` prompt: scripts/vault/ctl-env.sh reads it with echo OFF into the env,
# so the 42ctl image runs non-interactively. Override the project with VAULT_ENV_PROJECT.
vault-push-env: ## vault42: push every *.env*/*.secrets (any depth) to the REMOTE ZK vault — passphrase read hidden
	@REPO_DIR="$(CURDIR)" CTL_IMAGE="$(CTL_IMAGE)" CTL_CFG_DIR="$(CTL_CFG_DIR)" VAULT_ENV_PROJECT="$(VAULT_ENV_PROJECT)" \
		sh scripts/vault/ctl-env.sh push

vault-pull-env: ## vault42: restore the *.env* tree from the REMOTE ZK vault — DRY-RUN unless APPLY=1 (FORCE=1 overwrites existing files) — passphrase read hidden
	@REPO_DIR="$(CURDIR)" CTL_IMAGE="$(CTL_IMAGE)" CTL_CFG_DIR="$(CTL_CFG_DIR)" VAULT_ENV_PROJECT="$(VAULT_ENV_PROJECT)" \
		sh scripts/vault/ctl-env.sh pull $(if $(filter 1,$(APPLY)),--apply,) $(if $(filter 1,$(FORCE)),--force,)
