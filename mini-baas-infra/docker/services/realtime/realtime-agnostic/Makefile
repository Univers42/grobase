# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

.PHONY: help build test up down logs clean seed status dev audit audit-local audit-fetch \
	docker-login docker-build docker-push docker-update docker-tag docker-pull \
        docker-release docker-build-release docker-push-release \
        docker-login-ghcr docker-ghcr-push

# Read credentials from .env (never commit secrets).
-include .env
export

DOCKER_USER    ?= dlesieur
DOCKER_REPO    ?= realtime-agnostic
GITHUB_ORG     ?= Univers42
IMAGE_NAME     := $(DOCKER_USER)/$(DOCKER_REPO)
GHCR_IMAGE     := ghcr.io/$(shell echo $(GITHUB_ORG) | tr '[:upper:]' '[:lower:]')/$(DOCKER_REPO)
# Version: use git tag if present, otherwise git short hash, fallback to "dev".
VERSION        ?= $(shell git describe --tags --exact-match 2>/dev/null || \
                         git rev-parse --short HEAD 2>/dev/null || echo "dev")
# Release version: use the workspace Cargo.toml version for published images.
RELEASE_VERSION ?= $(shell awk -F '"' '/^version =/ { print $$2; exit }' Cargo.toml)
COMPOSE := docker compose -f sandbox/docker-compose.yml
PROJECT := realtime-agnostic

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

# Cargo runs INSIDE Docker (Docker-first: no rustc/cargo on the host). The
# registry and target dirs are named volumes shared with the mini-baas-infra
# Makefile targets, so build state stays warm across both entry points.
RUST_TOOLCHAIN_IMG ?= mini-baas-rust-toolchain
CARGO_RUN = docker run --rm -v "$(CURDIR)":/work -w /work \
	-v mini-baas-cargo-registry:/usr/local/cargo/registry \
	-v mini-baas-cargo-git:/usr/local/cargo/git \
	-v mini-baas-realtime-target:/work/target $(RUST_TOOLCHAIN_IMG)

_toolchain:
	@printf 'FROM public.ecr.aws/docker/library/rust:1.89-slim-bookworm\nRUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*\n' \
		| docker build -q -t $(RUST_TOOLCHAIN_IMG) - >/dev/null

build: _toolchain ## Build the Rust workspace (release, in Docker)
	$(CARGO_RUN) cargo build --release --workspace

test: _toolchain ## Run all tests (78 unit + integration, in Docker)
	$(CARGO_RUN) cargo test --workspace

# --quiet prints only warnings/errors AND keeps cargo's exit code (the old
# `| grep -v` filter exited 1 whenever a clean check produced no output).
check: _toolchain ## Check compilation with zero warnings (in Docker)
	$(CARGO_RUN) cargo check --workspace --quiet

audit: ## Run full audit: local checks + SonarCloud report → reports/
	@./scripts/audit.sh

audit-local: ## Run local-only audit (fmt, clippy, test, CVE, deps)
	@./scripts/audit.sh --local-only

audit-fetch: ## Fetch SonarCloud report only → reports/sonarcloud-issues.{json,txt}
	@./scripts/audit.sh --fetch-only

up: ## Start databases + server via Docker Compose
	$(COMPOSE) up --build -d
	@echo ""
	@echo "  ┌──────────────────────────────────────────────┐"
	@echo "  │  SyncSpace is starting...                    │"
	@echo "  │                                              │"
	@echo "  │  Web UI:    http://localhost:4002             │"
	@echo "  │  Health:    http://localhost:4002/v1/health   │"
	@echo "  │  WebSocket: ws://localhost:4002/ws            │"
	@echo "  │                                              │"
	@echo "  │  PostgreSQL: localhost:5434                   │"
	@echo "  │  MongoDB:    localhost:27019                  │"
	@echo "  │                                              │"
	@echo "  │  Logs:  make logs                            │"
	@echo "  │  Stop:  make down                            │"
	@echo "  └──────────────────────────────────────────────┘"
	@echo ""

down: ## Stop all containers
	$(COMPOSE) down

clean: ## Stop containers AND remove volumes (fresh start)
	$(COMPOSE) down -v --remove-orphans
	@echo "Cleaned all containers and volumes."

logs: ## Tail all container logs
	$(COMPOSE) logs -f

logs-server: ## Tail only the Rust server logs
	$(COMPOSE) logs -f realtime-server

logs-pg: ## Tail PostgreSQL logs
	$(COMPOSE) logs -f postgres

logs-mongo: ## Tail MongoDB logs
	$(COMPOSE) logs -f mongo

status: ## Show running containers
	$(COMPOSE) ps

restart: ## Restart the server (rebuild)
	$(COMPOSE) up --build -d realtime-server

seed: ## Re-seed databases (requires running containers)
	@echo "Re-seeding PostgreSQL..."
	$(COMPOSE) exec -T postgres psql -U syncspace syncspace < sandbox/db/postgres-seed.sql
	@echo "Re-seeding MongoDB..."
	$(COMPOSE) exec -T mongo mongosh syncspace /seed.js || \
		docker run --rm --network realtime-agnostic_default \
			-v $(PWD)/sandbox/db/mongo-seed.js:/seed.js:ro \
			mongo:7 mongosh --host mongo syncspace /seed.js
	@echo "Seed complete."

dev: ## Run Rust server locally and open browser (expects PG:5432, Mongo:27017)
	@echo "Stopping existing local servers..."
	-@pkill -x realtime-server || true
	@echo "Starting Rust server on http://localhost:4001 and opening browser..."
	@sleep 2 && (xdg-open http://localhost:4001 || open http://localhost:4001) >/dev/null 2>&1 &
	RUST_LOG=info,realtime_gateway=debug,realtime_server=debug \
	REALTIME_HOST=0.0.0.0 \
	REALTIME_PORT=4001 \
	REALTIME_STATIC_DIR=sandbox/static \
	cargo run --bin realtime-server

psql: ## Open psql shell to the database
	$(COMPOSE) exec postgres psql -U syncspace syncspace

mongo-shell: ## Open mongosh to the database
	$(COMPOSE) exec mongo mongosh syncspace

health: ## Check server health endpoint
	@curl -s http://localhost:4002/v1/health | python3 -m json.tool 2>/dev/null || \
		echo "Server not reachable at localhost:4002"

test-publish: ## Publish a test event via REST API
	@curl -s -X POST http://localhost:4002/v1/publish \
		-H "Content-Type: application/json" \
		-d '{"topic":"board:board-roadmap/card.created","event_type":"card.created","payload":{"id":"test-card","list_id":"list-backlog","title":"Test Card from Makefile","position":99,"assignee_id":"user-alice","label_color":"#ef4444","created_by":"user-alice"}}' \
		| python3 -m json.tool 2>/dev/null || echo "Publish failed"

test-ws: ## Quick WebSocket test (requires websocat)
	@echo '{"type":"AUTH","token":"test"}' | \
		timeout 3 websocat ws://localhost:4002/ws 2>/dev/null || \
		echo "Install websocat: cargo install websocat"

docker-login: ## Log in to Docker Hub using PAT from .env
	@set -a; . ./.env; set +a; \
	printf '%s' "$$PAT" | docker login -u "$$login_name" --password-stdin
	@echo "Logged in as $$login_name"

docker-build: ## Build Docker image  →  dlesieur/realtime-agnostic:<version>
	@echo "Building $(IMAGE_NAME):$(VERSION) ..."
	docker build \
		--tag $(IMAGE_NAME):$(VERSION) \
		--tag $(IMAGE_NAME):latest \
		--label "org.opencontainers.image.revision=$(VERSION)" \
		--label "org.opencontainers.image.created=$(shell date -u +%Y-%m-%dT%H:%M:%SZ)" \
		.
	@echo ""
	@echo "  Built: $(IMAGE_NAME):$(VERSION)"
	@echo "  Built: $(IMAGE_NAME):latest"

docker-push: ## Push image to Docker Hub (run docker-login first)
	docker push $(IMAGE_NAME):$(VERSION)
	docker push $(IMAGE_NAME):latest
	@echo ""
	@echo "  Pushed: $(IMAGE_NAME):$(VERSION)"
	@echo "  Pushed: $(IMAGE_NAME):latest"
	@echo "  Hub:    https://hub.docker.com/r/$(IMAGE_NAME)"

docker-update: docker-login docker-build docker-push ## Full update cycle: login → build → push
	@echo ""
	@echo "  ┌──────────────────────────────────────────────────┐"
	@echo "  │  Image updated on Docker Hub                     │"
	@echo "  │                                                  │"
	@echo "  │  docker pull $(IMAGE_NAME):latest"
	@echo "  │                                                  │"
	@echo "  │  In your mini-baas docker-compose.yml:           │"
	@echo "  │    image: $(IMAGE_NAME):latest  │"
	@echo "  └──────────────────────────────────────────────────┘"

docker-tag: ## Tag current image with a semantic version  (make docker-tag VERSION=1.0.0)
ifndef VERSION
	$(error VERSION is not set — use: make docker-tag VERSION=1.0.0)
endif
	docker tag $(IMAGE_NAME):latest $(IMAGE_NAME):$(VERSION)
	@echo "Tagged $(IMAGE_NAME):latest → $(IMAGE_NAME):$(VERSION)"

docker-pull: ## Pull latest image from Docker Hub (useful in mini-baas)
	docker pull $(IMAGE_NAME):latest

docker-login-ghcr: ## Log in to GitHub Container Registry (needs GITHUB_TOKEN in .env)
	@set -a; . ./.env; set +a; \
	printf '%s' "$$GITHUB_TOKEN" | docker login ghcr.io -u "$$GITHUB_ACTOR" --password-stdin
	@echo "Logged in to ghcr.io"

docker-ghcr-push: ## Push image to GitHub Container Registry (also shows under repo Packages tab)
	docker tag $(IMAGE_NAME):$(VERSION) $(GHCR_IMAGE):$(VERSION)
	docker tag $(IMAGE_NAME):latest      $(GHCR_IMAGE):latest
	docker push $(GHCR_IMAGE):$(VERSION)
	docker push $(GHCR_IMAGE):latest
	@echo ""
	@echo "  Pushed: $(GHCR_IMAGE):$(VERSION)"
	@echo "  Pushed: $(GHCR_IMAGE):latest"
	@echo "  Packages: https://github.com/$(GITHUB_ORG)/$(DOCKER_REPO)/pkgs/container/$(DOCKER_REPO)"

docker-build-release: ## Build Docker image tagged with the workspace version + latest
	@echo "Building $(IMAGE_NAME):$(RELEASE_VERSION) ..."
	docker build \
		--tag $(IMAGE_NAME):$(RELEASE_VERSION) \
		--tag $(IMAGE_NAME):latest \
		--label "org.opencontainers.image.revision=$(RELEASE_VERSION)" \
		--label "org.opencontainers.image.created=$(shell date -u +%Y-%m-%dT%H:%M:%SZ)" \
		.
	@echo ""
	@echo "  Built: $(IMAGE_NAME):$(RELEASE_VERSION)"
	@echo "  Built: $(IMAGE_NAME):latest"

docker-push-release: ## Push versioned Docker image + latest to Docker Hub
	docker push $(IMAGE_NAME):$(RELEASE_VERSION)
	docker push $(IMAGE_NAME):latest
	@echo ""
	@echo "  Pushed: $(IMAGE_NAME):$(RELEASE_VERSION)"
	@echo "  Pushed: $(IMAGE_NAME):latest"
	@echo "  Hub:    https://hub.docker.com/r/$(IMAGE_NAME)"

docker-release: docker-login docker-build-release docker-push-release ## Full release cycle using Cargo.toml version
	@echo ""
	@echo "  ┌──────────────────────────────────────────────────┐"
	@echo "  │  Release image published                         │"
	@echo "  │                                                  │"
	@echo "  │  docker pull $(IMAGE_NAME):$(RELEASE_VERSION)"
	@echo "  │  docker pull $(IMAGE_NAME):latest"
	@echo "  │                                                  │"
	@echo "  │  In mini-baas:                                   │"
	@echo "  │    image: $(IMAGE_NAME):$(RELEASE_VERSION)       │"
	@echo "  └──────────────────────────────────────────────────┘"
