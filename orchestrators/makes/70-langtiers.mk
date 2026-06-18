# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    70-langtiers.mk                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:41 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 22:59:43 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

NODE_IMAGE := public.ecr.aws/docker/library/node:20-alpine
NODE_RUN    = docker run --rm -v "$(CURDIR)/src":/app -w /app \
	-v mini-baas-src-node-modules:/app/node_modules \
	-v mini-baas-npm-cache:/root/.npm \
	$(NODE_IMAGE)

nestjs-ci: ## TS: install + typecheck + lint + test (in Docker)
	@$(NODE_RUN) sh -c 'npm ci --ignore-scripts --prefer-offline --no-audit --no-fund \
		&& npx tsc --noEmit && npx eslint "apps/**/*.ts" "libs/**/*.ts" && npx jest --passWithNoTests'
nestjs-build-%: ## TS: build one app in Docker (e.g. make nestjs-build-query-router)
	@$(NODE_RUN) sh -c '[ -x node_modules/.bin/nest ] || npm ci --ignore-scripts --prefer-offline --no-audit --no-fund; npx nest build $*'

sdk-test: ## SDK: build + run the @grobase/js node:test suite (in Docker; engines.ts is committed, codegen proven by m57/m58)
	@docker run --rm -v "$(CURDIR)":/repo -w /repo/sdks/js node:20-bookworm-slim \
		sh -c 'npm ci --no-audit --no-fund && npm run build && npm test'

# ── SonarCloud: coverage reports + scan ──────────────────────────────────────
# Regenerate the two lcov reports Sonar reads — jest (src/) + deno
# (functions-runtime) — rewriting SF paths project-relative so they match Sonar's
# file keys (sonar-project.properties points at the *.sonar.info variants).
# Docker-first: node + deno run in containers; coverage/ is gitignored (ephemeral).
DENO_IMAGE   := denoland/deno:alpine-2.1.4
FUNCS_DIR    := infra/docker/services/functions-runtime

sonar-coverage: ## Regenerate jest + deno lcov.sonar.info reports for SonarCloud
	@echo "▶ jest coverage (src/) …"
	@$(NODE_RUN) sh -c '[ -x node_modules/.bin/jest ] || npm ci --ignore-scripts --prefer-offline --no-audit --no-fund; \
		npx jest --coverage --coverageReporters=lcovonly --silent'
	@docker run --rm -v "$(CURDIR)/src/coverage":/c -w /c $(NODE_IMAGE) \
		sh -c "sed -e 's#^SF:apps/#SF:src/apps/#' -e 's#^SF:libs/#SF:src/libs/#' lcov.info > lcov.sonar.info"
	@echo "▶ deno coverage ($(FUNCS_DIR)) …"
	@docker run --rm -v "$(CURDIR)/$(FUNCS_DIR)":/app -w /app -e DENO_DIR=/deno-cache -v mini-baas-deno-cache:/deno-cache $(DENO_IMAGE) \
		sh -c 'rm -rf cov; deno test --allow-net --coverage=cov src/usage-meter.test.ts >/dev/null 2>&1; \
			mkdir -p coverage; deno coverage cov --lcov --output=coverage/deno.lcov.info; rm -rf cov; \
			sed "s#^SF:/app/src/#SF:$(FUNCS_DIR)/src/#" coverage/deno.lcov.info > coverage/deno.lcov.sonar.info'
	@echo "✓ regenerated src/coverage/lcov.sonar.info + $(FUNCS_DIR)/coverage/deno.lcov.sonar.info"

sonar-scan: sonar-coverage ## Regenerate coverage, then run the SonarCloud scanner (token: env SONAR_TOKEN/TOK_SONARCLOUD, else .env / ../.env)
	@TOKEN="$${SONAR_TOKEN:-$$TOK_SONARCLOUD}"; \
	for f in .env ../.env; do \
		[ -n "$$TOKEN" ] && break; \
		[ -f "$$f" ] && TOKEN="$$(grep -E '^[[:space:]]*(export[[:space:]]+)?(SONAR_TOKEN|TOK_SONARCLOUD)=' "$$f" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$$//')"; \
	done; \
	[ -n "$$TOKEN" ] || { echo "✗ No SonarCloud token. Set SONAR_TOKEN (or TOK_SONARCLOUD) in the environment, or add it to .env / ../.env"; exit 1; }; \
	echo "▶ SonarCloud scan (org=univers42 project=Univers42_grobase) …"; \
	docker run --rm -e SONAR_TOKEN="$$TOKEN" -v "$(CURDIR)":/usr/src -w /usr/src \
		sonarsource/sonar-scanner-cli:latest sonar-scanner

# Cargo runs INSIDE Docker (no rustc/cargo on the host). The registry and the
# per-workspace target dirs live in named volumes, so dependency downloads and
# incremental build state persist across runs while the host stays clean.
RUST_IMAGE          := public.ecr.aws/docker/library/rust:1.96-slim-bookworm
RUST_TOOLCHAIN_IMG  := mini-baas-rust-toolchain
CARGO_VOLS           = -v mini-baas-cargo-registry:/usr/local/cargo/registry -v mini-baas-cargo-git:/usr/local/cargo/git
CARGO_DPR            = docker run --rm -v "$(CURDIR)/src/data-plane-router":/work -w /work $(CARGO_VOLS) -v mini-baas-dpr-target:/work/target $(RUST_TOOLCHAIN_IMG)
CARGO_REALTIME       = docker run --rm -v "$(CURDIR)/infra/docker/services/realtime/realtime-agnostic":/work -w /work $(CARGO_VOLS) -v mini-baas-realtime-target:/work/target $(RUST_TOOLCHAIN_IMG)

_rust-toolchain: ## (internal) cargo-in-docker image: rust + pkg-config/libssl (layer-cached)
	@printf 'FROM $(RUST_IMAGE)\nRUN rustup component add clippy rustfmt && apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*\n' \
		| docker build -q -t $(RUST_TOOLCHAIN_IMG) - >/dev/null

rust-data-plane-check: _rust-toolchain ## Rust: cargo check the data-plane workspace (in Docker)
	@$(CARGO_DPR) cargo clippy --workspace --all-targets -- -D warnings

rust-data-plane-test: _rust-toolchain ## Rust: run the data-plane workspace unit + integration tests (in Docker)
	@$(CARGO_DPR) cargo test --workspace

# Engine conformance: run the reusable battery (crates/engine-conformance)
# against ONE live engine over the mini-baas network. DSN is discovered from
# the running engine container (env + in-network alias), so a wrong host env
# can't poison it. New engines (Phase 3) only merge once `conformance-<engine>`
# is green. `make conformance` runs the whole gate (scripts/verify/m27).
CONFORMANCE_NET = $(shell docker inspect mini-baas-postgres --format '{{range $$k,$$v := .NetworkSettings.Networks}}{{$$k}}{{end}}' 2>/dev/null | head -1)
conformance-%: _rust-toolchain ## Rust: run the engine-conformance battery for ONE engine (e.g. make conformance-postgresql)
	@bash scripts/verify/m27-conformance.sh $*
conformance: ## Rust: run the engine-conformance gate for every live engine (m27)
	@bash scripts/verify/m27-conformance.sh
rust-data-plane-build: _rust-toolchain ## Rust: build the data-plane release binary (in Docker)
	@$(CARGO_DPR) cargo build --release --bin data-plane-router

# ── binocle-nano: the single-binary PocketBase-class edition ────────────────
# One static musl binary (embedded SQLite, in-process auth, SSE realtime) in
# a FROM scratch image — measured ~5 MB image / ~2 MiB idle RSS. Gate: m37.
nano-build: ## Nano: build the binocle-nano scratch image (static musl, ~5 MB)
	@DOCKER_BUILDKIT=1 docker build -f src/data-plane-router/Dockerfile.nano \
		-t binocle-nano src/data-plane-router
	@docker images binocle-nano --format '$(_G)✓ binocle-nano built — {{.Size}}$(_0)'

nano-up: nano-build ## Nano: run binocle-nano on :8090 (named volume nano-data)
	@docker rm -f binocle-nano >/dev/null 2>&1 || true
	@docker run -d --name binocle-nano -p 8090:8090 -v nano-data:/data binocle-nano >/dev/null
	@sleep 1; docker logs binocle-nano 2>&1 | head -5
	@echo -e "$(_G)✓ binocle-nano on http://localhost:8090 (admin key above on FIRST boot only)$(_0)"

nano-down: ## Nano: stop binocle-nano (data volume persists)
	@docker rm -f binocle-nano >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ binocle-nano stopped (volume nano-data kept)$(_0)"

# ── binocle-one: "our PocketBase" — nano + user accounts (JWT). Gate: m40. ──
one-build: ## One: build the binocle-one scratch image (nano + accounts)
	@DOCKER_BUILDKIT=1 docker build -f src/data-plane-router/Dockerfile.one \
		-t binocle-one src/data-plane-router
	@docker images binocle-one --format '$(_G)✓ binocle-one built — {{.Size}}$(_0)'

one-up: one-build ## One: run binocle-one on :8091 (named volume one-data)
	@docker rm -f binocle-one >/dev/null 2>&1 || true
	@docker run -d --name binocle-one -p 8091:8090 -v one-data:/data binocle-one >/dev/null
	@sleep 1; docker logs binocle-one 2>&1 | head -5
	@echo -e "$(_G)✓ binocle-one on http://localhost:8091 (admin key above on FIRST boot only)$(_0)"

one-down: ## One: stop binocle-one (data volume persists)
	@docker rm -f binocle-one >/dev/null 2>&1 || true
	@echo -e "$(_G)✓ binocle-one stopped (volume one-data kept)$(_0)"

rust-realtime-check: _rust-toolchain ## Rust: cargo check the realtime workspace (in Docker)
	@$(CARGO_REALTIME) cargo check --workspace
rust-realtime-test: _rust-toolchain ## Rust: run the realtime unit tests (in Docker)
	@$(CARGO_REALTIME) cargo test --workspace
rust-realtime-build: _rust-toolchain ## Rust: build the realtime-server release binary (in Docker)
	@$(CARGO_REALTIME) cargo build --release --bin realtime-server
go-control-plane-check: ## Go: vet + test the control-plane module (in Docker, cached modules)
	@docker run --rm -v "$(CURDIR)/src/control-plane":/src -w /src \
		-v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build \
		golang:1.25-bookworm sh -c 'GOFLAGS=-mod=mod go vet ./... && GOFLAGS=-mod=mod go test ./...'
go-control-plane-build: ## Go: build the control-plane images
	@$(DC) --profile go-control-plane build
