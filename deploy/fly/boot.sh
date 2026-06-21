#!/usr/bin/env bash
# Single-Machine grobase backend boot: dockerd (DinD on the fly volume) → clone
# main → assemble prod .env → migrate → bring the curated 17-service stack up.
# Kong is the only public door; everything else stays on the inner docker network.
set -euo pipefail

DATA=/data
REPO="$DATA/grobase"
DOCKER_ROOT="$DATA/docker"
SECRETS_SAVE="$DATA/env.secrets"
LOCAL_SAVE="$DATA/env.local"
MIGRATED="$DATA/.migrated"
PROVISIONED="$DATA/.provisioned"
PUBLIC_HOST="${PUBLIC_HOST:-grobase-stack.fly.dev}"
REPO_URL="${REPO_URL:-https://github.com/Univers42/grobase.git}"
OVERRIDE="/opt/compose.override.yml"
DC="docker compose -f docker-compose.yml -f $OVERRIDE"
CONTRACTS="website vault42"
SERVICES="postgres db-bootstrap gotrue mailpit kong postgrest redis realtime \
mongo mongo-init mongo-keyfile tenant-control adapter-registry-go \
data-plane-router-rust query-router log-service permission-engine"

log() { printf '\n[boot] %s\n' "$*"; }

start_dockerd() {
	mkdir -p "$DOCKER_ROOT"
	log "starting dockerd (data-root=$DOCKER_ROOT)"
	dockerd-entrypoint.sh dockerd --data-root="$DOCKER_ROOT" \
		--host=unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
	for _ in $(seq 1 90); do docker info >/dev/null 2>&1 && return 0; sleep 1; done
	log "dockerd failed"; tail -50 /var/log/dockerd.log; exit 1
}

sync_repo() {
	if [ -d "$REPO/.git" ]; then
		log "updating repo"
		git -C "$REPO" fetch --depth 1 origin main && git -C "$REPO" reset --hard origin/main
	else
		log "cloning $REPO_URL"; git clone --depth 1 "$REPO_URL" "$REPO"
	fi
}

write_local_overrides() {
	local pepper
	if [ -f "$DATA/.pepper" ]; then pepper="$(cat "$DATA/.pepper")"
	else pepper="$(openssl rand -hex 32)"; printf '%s' "$pepper" >"$DATA/.pepper"; fi
	cat >.env.local <<-EOF
		API_EXTERNAL_URL=https://$PUBLIC_HOST/auth/v1
		GOTRUE_SITE_URL=https://$PUBLIC_HOST
		GOTRUE_URI_ALLOW_LIST=https://$PUBLIC_HOST/**
		SUPABASE_URL=https://$PUBLIC_HOST
		SUPABASE_PUBLIC_URL=https://$PUBLIC_HOST
		FRONTEND_URL=https://$PUBLIC_HOST
		KONG_CORS_ORIGIN_FRONTEND=https://$PUBLIC_HOST
		KONG_CORS_ORIGIN_APP=https://$PUBLIC_HOST
		KONG_CORS_ORIGIN_PLAYGROUND=https://$PUBLIC_HOST
		KONG_CORS_ORIGIN_STUDIO=https://$PUBLIC_HOST
		IDENTITY_HEADER_MODE=strict
		GOTRUE_MAILER_AUTOCONFIRM=true
		EMAIL_OTP_ENABLED=1
		KEY_HASH_PEPPER=$pepper
		EMAIL_OTP_TTL_SECS=300
		EMAIL_OTP_MAX_ATTEMPTS=5
	EOF
	# Real SMTP from fly secrets (set SMTP_PASS on the app) routes OTP/mail to a real
	# inbox; absent it, the stack keeps the internal mailpit sink (dev default).
	if [ -n "${SMTP_PASS:-}" ]; then
		cat >>.env.local <<-EOF
			SMTP_HOST=${SMTP_HOST:-smtp.gmail.com}
			SMTP_PORT=${SMTP_PORT:-587}
			SMTP_SECURE=${SMTP_SECURE:-false}
			SMTP_USER=${SMTP_USER:-dev.pro.photo@gmail.com}
			SMTP_PASS=$SMTP_PASS
			EMAIL_FROM=${EMAIL_FROM:-dev.pro.photo@gmail.com}
			GOTRUE_SMTP_HOST=${SMTP_HOST:-smtp.gmail.com}
			GOTRUE_SMTP_PORT=${SMTP_PORT:-587}
			GOTRUE_SMTP_USER=${SMTP_USER:-dev.pro.photo@gmail.com}
			GOTRUE_SMTP_PASS=$SMTP_PASS
			GOTRUE_SMTP_ADMIN_EMAIL=${EMAIL_FROM:-dev.pro.photo@gmail.com}
		EOF
	fi
}

assemble_env() {
	cd "$REPO"
	[ -f "$SECRETS_SAVE" ] && cp "$SECRETS_SAVE" .env.secrets
	write_local_overrides
	bash scripts/env/assemble-env.sh
	cp .env.secrets "$SECRETS_SAVE"; cp .env.local "$LOCAL_SAVE"
}

maybe_reset() {
	local want have
	want="${RESET:-0}"
	have="$([ -f "$DATA/.reset_token" ] && cat "$DATA/.reset_token" || true)"
	{ [ "$want" != "0" ] && [ "$want" != "$have" ]; } || return 0
	log "RESET=$want (one-shot): docker compose down -v + clearing migration marker"
	$DC down -v || true
	rm -f "$MIGRATED"
	printf '%s' "$want" >"$DATA/.reset_token"
}

wait_for_auth() {
	log "waiting for gotrue to create auth.users…"
	for _ in $(seq 1 80); do
		docker exec -i mini-baas-postgres psql -U postgres -d postgres \
			-c "select 1 from auth.users limit 0" >/dev/null 2>&1 &&
			{ log "auth.users present"; return 0; }
		sleep 3
	done
	log "auth.users still absent after wait — gotrue slow/unhealthy"
}

apply_migrations() {
	for f in $(ls -1 scripts/migrations/postgresql/*.sql 2>/dev/null | sort); do
		printf '  migrate: %s\n' "$f"
		sed '/^#/d' "$f" | docker exec -i mini-baas-postgres psql -U postgres -d postgres \
			-v ON_ERROR_STOP=1 -f - >/dev/null || { log "FAILED: $f"; return 1; }
	done
}

bring_up() {
	cd "$REPO"
	log "pulling images"; $DC pull $SERVICES || true
	log "up auth tier (gotrue + deps create auth.users)"; $DC up -d gotrue || log "gotrue tier issue"
	wait_for_auth
	if [ -f "$MIGRATED" ]; then
		log "SQL migrations already applied (marker present) — skipping"
	else
		log "applying SQL migrations (first boot)"
		apply_migrations && touch "$MIGRATED" || log "migration errors — not marking complete"
	fi
	log "up full stack"
	$DC up -d --no-build $SERVICES ||
		{ sleep 15; $DC up -d --no-build $SERVICES || log "some services unhealthy — inspect via ssh"; }
	log "restart control plane so ensureSchema/schema-checks see the migrated DB"
	$DC restart adapter-registry-go tenant-control || true
	wait_for_registry
	ensure_gateway
}

ensure_gateway() {
	# mongo's healthcheck can exceed its 3s timeout under load on a cold reboot,
	# which strands the realtime→kong depends_on chain ("kong Created", public door
	# down). mongo still serves fine; force the chain up with --no-deps so the public
	# gateway recovers without manual intervention.
	log "ensuring gateway chain (mongo-init → realtime → kong) is up"
	$DC up -d --no-deps mongo-init || true
	sleep 4
	$DC up -d --no-deps realtime || true
	sleep 3
	$DC up -d --no-deps kong || true
}

wait_for_registry() {
	log "waiting for adapter-registry-go healthy…"
	for _ in $(seq 1 40); do
		[ "$(docker inspect -f '{{.State.Health.Status}}' mini-baas-adapter-registry-go 2>/dev/null)" = healthy ] &&
			{ log "adapter-registry-go healthy"; return 0; }
		sleep 3
	done
	log "adapter-registry-go not healthy after wait"
}

provision_apps() {
	[ -f "$PROVISIONED" ] && { log "apps already provisioned — skipping"; return 0; }
	local ok=1
	for c in $CONTRACTS; do
		log "provisioning contract: $c"
		KONG_URL=http://127.0.0.1:8000 bash scripts/provision-contract.sh \
			"infra/config/contracts/$c.json" 2>&1 | tail -8 || { ok=0; log "provision $c failed"; }
	done
	[ "$ok" = 1 ] && touch "$PROVISIONED" || log "provision incomplete — will retry next boot"
}

main() {
	start_dockerd; sync_repo; assemble_env; maybe_reset
	cd "$REPO"; log "clean container slate (keeping data volume)"; $DC down --remove-orphans || true
	bring_up
	provision_apps
	log "stack up — public https://$PUBLIC_HOST (Kong :8000)"
	exec $DC logs -f kong gotrue tenant-control data-plane-router-rust query-router
}

main "$@"
