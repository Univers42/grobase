# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    40-tests.mk                                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 22:59:56 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 22:59:57 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

test-smoke: ## Run all phase smoke tests (phase1→N) vs the live stack
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	export PUBLIC_APIKEY=$${PUBLIC_APIKEY:-$$APIKEY}; \
	export SERVICE_ROLE_KEY=$${SERVICE_ROLE_KEY:-$$(grep '^SERVICE_ROLE_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	rc=0; for s in $$(ls -1 ./scripts/test/phase/phase*-*.sh ./scripts/test/phase/phase*-*.py 2>/dev/null | sort -t/ -k3 -V); do \
		case "$$s" in *.py) FORCE_COLORS=1 python3 "$$s" ;; *) FORCE_COLORS=1 bash "$$s" ;; esac || rc=1; sleep 1; \
	done; exit $$rc

test-phase%: ## Run one phase (e.g. make test-phase3)
	@export APIKEY=$${APIKEY:-$$(grep '^ANON_KEY=' .env 2>/dev/null | cut -d= -f2-)}; \
	s=$$(ls scripts/test/phase/phase$*-*.sh scripts/test/phase/phase$*-*.py 2>/dev/null | head -1); \
	[ -n "$$s" ] || { echo -e "$(_R)No test for phase $*$(_0)"; exit 1; }; \
	case "$$s" in *.py) FORCE_COLORS=1 python3 "$$s" ;; *) FORCE_COLORS=1 bash "$$s" ;; esac

test-postgres: ## Run the PostgreSQL MVP happy-path flow
	@FORCE_COLORS=1 bash ./scripts/test/phase/postgres-mvp-flow.sh

test-offers: ## Postman/newman offer-capability proof vs the LIVE stack → artifacts/test/postman-offers-report.html (NEWMAN_IMAGE=)
	@bash scripts/test/postman/run-postman.sh

test-edge: ## Data-driven edge corpus (1500+ vectors, one newman iteration each) vs the LIVE data plane → artifacts/test/edge-report.html
	@bash scripts/test/postman/run-edge-postman.sh

test-unit: ## Run ALL source-level unit tests (Go + Rust data-plane + Rust realtime + NestJS) — no live stack needed
	@rc=0; \
	echo -e "$(_B)── Go control-plane (go test ./...) ──$(_0)";   $(MAKE) --no-print-directory go-control-plane-check || rc=1; \
	echo -e "$(_B)── Rust data-plane (cargo test) ──$(_0)";       $(MAKE) --no-print-directory rust-data-plane-test   || rc=1; \
	echo -e "$(_B)── Rust realtime (cargo test) ──$(_0)";         $(MAKE) --no-print-directory rust-realtime-test     || rc=1; \
	echo -e "$(_B)── NestJS apps + libs (jest) ──$(_0)";          $(MAKE) --no-print-directory nestjs-ci              || rc=1; \
	if [ $$rc -eq 0 ]; then echo -e "$(_G)✓ unit tests passed$(_0)"; else echo -e "$(_R)✗ unit tests failed$(_0)"; exit 1; fi

test-all: ## Run EVERYTHING available: unit + (if the stack is up) integration phases, Postman offers + edge, WAF, conformance
	@rc=0; \
	$(MAKE) --no-print-directory test-unit || rc=1; \
	if docker ps --format '{{.Names}}' | grep -q '^mini-baas-kong$$'; then \
		echo -e "$(_B)── live-stack suites (stack detected) ──$(_0)"; \
		$(MAKE) --no-print-directory test-smoke  || rc=1; \
		$(MAKE) --no-print-directory test-offers || rc=1; \
		$(MAKE) --no-print-directory test-edge   || rc=1; \
		$(MAKE) --no-print-directory waf-test    || true; \
		$(MAKE) --no-print-directory conformance || rc=1; \
	else \
		echo -e "$(_Y)• stack down — skipping integration / Postman / edge / conformance (run 'make up' first)$(_0)"; \
	fi; \
	if [ $$rc -eq 0 ]; then echo -e "$(_G)✓ test-all green$(_0)"; else echo -e "$(_R)✗ test-all had failures$(_0)"; exit 1; fi

verify-%: ## Run a milestone gate (e.g. make verify-m18)
	@s=$$(ls scripts/verify/$*-*.sh 2>/dev/null | head -1); \
	[ -n "$$s" ] || { echo -e "$(_R)No verify gate '$*'$(_0)"; exit 1; }; \
	bash "$$s"

verify-all: ## Run every milestone gate (all scripts/verify/m*-*.sh, in version order)
	@rc=0; for s in $$(ls scripts/verify/m*-*.sh | sort -V); do \
		echo -e "$(_B)→ $$s$(_0)"; bash "$$s" || rc=1; done; exit $$rc

parity: ## Layer-swap parity gate (NEW=<url> [OLD=<url>] [ROUTES=<set>] [RECORD=1]) — emits a verdict
	@OLD="$(OLD)" NEW="$(NEW)" ROUTES="$(ROUTES)" bash scripts/verify/parity.sh $(if $(RECORD),--record,)

parity-suite: ## Legacy full-suite TS↔Rust shadow probe (restarts query-router; historical)
	@bash scripts/verify/parity-probe.sh

cutover-%: ## Gated promotion of a plane/service (runs parity, then restarts it) — override NEW=/ROUTES= per plane
	@echo -e "$(_Y)Cutover '$*' — requires a green parity verdict first.$(_0)"
	@$(MAKE) --no-print-directory parity NEW="$(or $(NEW),http://127.0.0.1:4011)" ROUTES="$(or $(ROUTES),data-plane-contract)"
	@$(DCE) up -d --no-deps $* && echo -e "$(_G)✓ '$*' restarted; set its *_PRODUCT_MODE=enabled in .env to make it live$(_0)"

deploy-gen: ## (G11) Compile the edition manifest → Helm values + Kustomize overlays (DEPLOY_REGISTRY=/DEPLOY_TAG= override images)
	@command -v python3 >/dev/null 2>&1 || { echo -e "$(_R)python3 required$(_0)"; exit 1; }
	@python3 scripts/deploy/gen-deploy.py

deploy-template: ## (G11) Render an edition's K8s manifests via Helm (EDITION=lean|query|realtime|analytics|prod|full)
	@command -v helm >/dev/null 2>&1 || { echo -e "$(_R)helm required$(_0)"; exit 1; }
	@helm template mini-baas deploy/helm/mini-baas -f deploy/helm/mini-baas/values-$(EDITION).yaml

waf-test: ## Confirm the WAF blocks SQLi/XSS at the edge
	@for q in "?id=1%20OR%201=1" "/<script>alert(1)</script>"; do \
		code=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost/rest/v1/$$q"); \
		[ "$$code" = "403" ] && echo "  ✓ blocked ($$q)" || echo "  ✗ expected 403, got $$code ($$q)"; \
	done
