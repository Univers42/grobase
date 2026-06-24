.PHONY: install start-back start-front start test lint build load-test clean

# ── Install ──────────────────────────────────────────────
install:
	cd back && npm install
	cd front && npm install

# ── Development ──────────────────────────────────────────
start-back:
	cd back && npm run start:dev

start-front:
	cd front && npx expo start

start: ## Start both back-end and front-end
	@echo "Starting back-end and front-end..."
	$(MAKE) start-back &
	$(MAKE) start-front

# ── Testing ──────────────────────────────────────────────
test:
	cd back && npm run test
	cd front && npm test

test-back:
	cd back && npm run test

test-e2e:
	cd back && npm run test:e2e

test-cov:
	cd back && npm run test:cov

# ── Linting ──────────────────────────────────────────────
lint:
	cd back && npm run lint
	cd front && npx expo lint

lint-back:
	cd back && npm run lint

lint-front:
	cd front && npx expo lint

# ── Build ────────────────────────────────────────────────
build:
	cd back && npm run build
	cd front && npx expo export --platform web

build-back:
	cd back && npm run build

build-front:
	cd front && npx expo export --platform web

# ── Load Testing ─────────────────────────────────────────
load-test:
	cd back && npx artillery run load-tests/scenarios.yml

# ── Clean ────────────────────────────────────────────────
clean:
	rm -rf back/dist back/node_modules front/node_modules front/.expo
