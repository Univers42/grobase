# ============================================
# VITE GOURMAND - Makefile
# ============================================
# Run 'make help' to see all available targets.
# Default: 'make' runs a full containerized bootstrap.
# Only Docker is required on the host machine.
# ============================================

SHELL := /usr/bin/bash
.SHELLFLAGS := -eo pipefail -c

.DEFAULT_GOAL := help

# -- Variables -------------------------------------------------------
# Auto-detect docker compose v2 plugin or v1 standalone
DOCKER_COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo 'docker compose' || echo 'docker-compose')


BACKEND_PATH  = ./Back
FRONTEND_PATH = ./View
SCRIPTS_PATH  = ./scripts
PRISMA_SCHEMA = $(BACKEND_PATH)/src/Model/prisma/schema.prisma

BACKEND_PORT  = 3000
FRONTEND_PORT = 5173

# PID files for background local dev servers
BACKEND_PID   = .backend.pid
FRONTEND_PID  = .frontend.pid

# Bitwarden vault item name (override: BW_ITEM_NAME=xxx make step-1-secrets)
# NOTE: Do NOT include Back/.env via include — Make corrupts URLs containing &.
BW_ITEM_NAME ?= vite-gourmand-env
export BW_ITEM_NAME

# -- Load extensions -------------------------------------------------
include $(wildcard mk_extensions/*.mk)

# -- Entry points ----------------------------------------------------
.PHONY: all bootstrap local deploy test secrets stop shell restart help

all: docker-bootstrap       ## Full containerized bootstrap (default)
bootstrap: docker-bootstrap ## Alias for docker-bootstrap
local: local-bootstrap      ## Bootstrap with host Node.js (requires npm)
deploy: deploy-fly          ## Deploy to Fly.io
test: test-unit             ## Run unit tests
secrets: step-1-secrets     ## Fetch Back/.env from Bitwarden
stop: docker-stop           ## Stop the dev container
shell: docker-shell         ## Open shell in the dev container
restart: docker-restart     ## Restart dev servers inside the container

# -- Help ------------------------------------------------------------
help: ## Show all available commands grouped by category
	@printf '\nVITE GOURMAND - Available Commands\n'
	@printf 'Host requirements: Docker only (containers run Node.js 22 Alpine).\n\n'
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/                  { printf "\n\033[1;33m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*##/  { printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@printf '\n'
