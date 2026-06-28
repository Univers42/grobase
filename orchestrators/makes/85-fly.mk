# **************************************************************************** #
#                                                                              #
#    85-fly.mk — fly.io + Vercel deployment lifecycle for grobase-stack        #
#                                                                              #
#    One operator surface for the managed-cloud deploy. flyctl/vercel run in   #
#    Docker (no host binary). Token resolved from env or .env.local at recipe  #
#    time. The app name is a pinned LITERAL — destructive targets never        #
#    iterate `fly apps list`, so the do-not-touch apps can't be hit.           #
#                                                                              #
# **************************************************************************** #

##@ Fly.io deploy lifecycle (grobase-stack)

# Pinned identifiers — never a wildcard. Override REGION/VOL only if you know why.
FLY_APP        := grobase-stack
FLY_REGION     ?= cdg
FLY_VOL        ?= grobase_data
FLY_CTX        := deploy/fly
FLYCTL_IMG     ?= flyio/flyctl:latest
VERCEL_IMG     ?= node:22-alpine
WEBSITE_DIR    := vendor/grobase-website

# fly = dockerised flyctl with the resolved token. $(1) = flyctl args.
# Token: $$FLY_TOKEN (env) else FLY_TOKEN= line in .env.local. No token → fail loud.
fly = tok="$${FLY_TOKEN:-$$(sed -n 's/^FLY_TOKEN=//p' .env.local 2>/dev/null | head -1)}"; \
      [ -n "$$tok" ] || { echo -e "$(_R)✗ FLY_TOKEN missing — set it in env or .env.local$(_0)" >&2; exit 1; }; \
      docker run --rm -i -e FLY_API_TOKEN="$$tok" $(FLYCTL_IMG) $(1)

# fly_ctx = flyctl with the deploy/fly build context mounted (for `deploy`).
fly_ctx = tok="$${FLY_TOKEN:-$$(sed -n 's/^FLY_TOKEN=//p' .env.local 2>/dev/null | head -1)}"; \
      [ -n "$$tok" ] || { echo -e "$(_R)✗ FLY_TOKEN missing — set it in env or .env.local$(_0)" >&2; exit 1; }; \
      docker run --rm -i -e FLY_API_TOKEN="$$tok" -v "$(CURDIR)/$(FLY_CTX):/work" -w /work $(FLYCTL_IMG) $(1)

# vercel = dockerised vercel CLI with the website dir mounted. $(1) = vercel args.
vercel = tok="$${VERCEL_TOKEN:-$$(sed -n 's/^VERCEL_TOKEN=//p' .env.local 2>/dev/null | head -1)}"; \
      [ -n "$$tok" ] || { echo -e "$(_R)✗ VERCEL_TOKEN missing — set it in env or .env.local$(_0)" >&2; exit 1; }; \
      docker run --rm -i -e VERCEL_TOKEN="$$tok" -v "$(CURDIR)/$(WEBSITE_DIR):/web" -w /web $(VERCEL_IMG) \
        npx --yes vercel@latest $(1) --token "$$tok"

# ── inspect / status ─────────────────────────────────────────────────────────

fly-status: ## fly: machine + app status for grobase-stack
	@$(call fly,status -a $(FLY_APP))

fly-list: ## fly: list machines for grobase-stack
	@$(call fly,machine list -a $(FLY_APP))

fly-volumes: ## fly: list volumes for grobase-stack
	@$(call fly,volumes list -a $(FLY_APP))

fly-secrets: ## fly: list secret NAMES (never values) for grobase-stack
	@$(call fly,secrets list -a $(FLY_APP))

fly-logs: ## fly: tail logs for grobase-stack (Ctrl-C to stop)
	@$(call fly,logs -a $(FLY_APP))

fly-url: ## fly: print the public URL + probe it
	@echo -e "$(_C)https://$(FLY_APP).fly.dev$(_0)"; \
	curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' "https://$(FLY_APP).fly.dev" || echo -e "$(_Y)unreachable$(_0)"

# ── deploy / update ──────────────────────────────────────────────────────────

fly-deploy: ## fly: build image (bakes boot.sh) + deploy grobase-stack (remote builder)
	@echo -e "$(_B)▶ deploying $(FLY_APP) (remote-only build of $(FLY_CTX))$(_0)"
	@$(call fly_ctx,deploy --remote-only -a $(FLY_APP) -c fly.toml)
	@echo -e "$(_G)✓ deployed — https://$(FLY_APP).fly.dev$(_0)"

fly-update: fly-deploy ## fly: alias of fly-deploy (rebuild + ship current source)

# ── runtime control ──────────────────────────────────────────────────────────

fly-start: ## fly: start grobase-stack machine(s)
	@$(call fly,machine start -a $(FLY_APP))
	@echo -e "$(_G)✓ start requested$(_0)"

fly-stop: ## fly: stop grobase-stack machine(s) (volume + app kept)
	@$(call fly,machine stop -a $(FLY_APP))
	@echo -e "$(_G)✓ stop requested$(_0)"

fly-restart: ## fly: restart grobase-stack machine(s)
	@$(call fly,machine restart -a $(FLY_APP))
	@echo -e "$(_G)✓ restart requested$(_0)"

fly-ssh: ## fly: ssh into grobase-stack (interactive console; or ARGS="-C 'cmd'")
	@tok="$${FLY_TOKEN:-$$(sed -n 's/^FLY_TOKEN=//p' .env.local 2>/dev/null | head -1)}"; \
	[ -n "$$tok" ] || { echo -e "$(_R)✗ FLY_TOKEN missing$(_0)" >&2; exit 1; }; \
	docker run --rm -it -e FLY_API_TOKEN="$$tok" $(FLYCTL_IMG) ssh console -a $(FLY_APP) $(ARGS)

# ── backup (run BEFORE any destroy) ──────────────────────────────────────────

fly-backup: ## fly: off-platform backup of vault42 ZK envelopes (durable; do before teardown)
	@echo -e "$(_B)▶ backing up vault42 envelopes off-platform$(_0)"
	@bash scripts/ops/backup-vault42-envelopes.sh 2>/dev/null || \
		echo -e "$(_Y)backup script unavailable — pg_dump via 'make fly-ssh ARGS=\"-C ...\"' instead$(_0)"

# ── destructive teardown (pinned literal app; CONFIRM=1 required) ────────────

fly-destroy: ## fly: DESTROY grobase-stack (machines+config+volume+edge). CONFIRM=1, runs fly-backup first
	@[ "$(CONFIRM)" = "1" ] || { echo -e "$(_R)refusing — re-run with CONFIRM=1 (this is irreversible)$(_0)"; exit 1; }
	@$(MAKE) --no-print-directory fly-backup
	@echo -e "$(_R)▶ stopping then destroying $(FLY_APP)$(_0)"
	@$(call fly,machine stop -a $(FLY_APP)) || true
	@$(call fly,apps destroy $(FLY_APP) --yes)
	@echo -e "$(_G)✓ $(FLY_APP) destroyed — verify with: make fly-status$(_0)"

# ── Vercel (website) ─────────────────────────────────────────────────────────

vercel-list: ## vercel: list projects (find the website before removing)
	@$(call vercel,projects ls)

vercel-deploy: ## vercel: build + deploy the website to prod (GROBASE_IN_DOCKER baked in)
	@echo -e "$(_B)▶ deploying $(WEBSITE_DIR) to Vercel (prod)$(_0)"
	@$(call vercel,deploy --prod --yes)
	@echo -e "$(_G)✓ website deployed$(_0)"

vercel-remove: ## vercel: remove a website project (NAME=<project>, CONFIRM=1)
	@[ "$(CONFIRM)" = "1" ] || { echo -e "$(_R)refusing — re-run with NAME=<project> CONFIRM=1$(_0)"; exit 1; }
	@[ -n "$(NAME)" ] || { echo -e "$(_R)NAME=<project> required$(_0)"; exit 1; }
	@$(call vercel,remove $(NAME) --safe --yes)
	@echo -e "$(_G)✓ removed $(NAME)$(_0)"

.PHONY: fly-status fly-list fly-volumes fly-secrets fly-logs fly-url \
        fly-deploy fly-update fly-start fly-stop fly-restart fly-ssh \
        fly-backup fly-destroy vercel-list vercel-deploy vercel-remove
