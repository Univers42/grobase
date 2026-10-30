#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    engine-tls-mongo-clients-live.sh                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 18:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 18:00:00 by dlesieur         ###   ########.fr       #
#                                                                              #
# **************************************************************************** #
#
# Sourced by m247-engine-tls.sh after engine-tls-mongo-clients.sh (MC_* names, mc_redact).
# Live leg D (M247_ENGINE=mongo, ADR 0025 M7/M9): mongo under requireTLS with real clients.
# Plaintext refused, a verified mongosh in, mongo healthy, mongo-init PRIMARY, mongo-api (Node)
# healthy, realtime (Rust) streaming and healthy at 45 s, the orchestrator's driver (Go) on its
# rendered DSN, and an engine-backup round trip. WORK, MONGO_EVAL and the password are m247's.
#
# Caveat: outbox-relay, ai and analytics are not booted (they share mongo-api's Node driver and
# are covered by the static census only), and the orchestrator is a probe linking its driver on
# its rendered DSN, not the orchestrator itself: a projector code path that rebuilds the URI
# would pass here and fail live.

# Names of their own, no host port. realtime waits on postgres alone: its PG producer only
# LISTENs, so leg D boots no db-bootstrap.
mc_clients_file() {
  cat >"${WORK}/clients.yml" <<YML
services:
  mongo-init:
    container_name: ${M247_PROJECT}-mongo-init
  mongo-api:
    container_name: ${M247_PROJECT}-mongo-api
  postgres:
    container_name: ${M247_PROJECT}-mongo-postgres
    ports: !reset []
  realtime:
    container_name: ${M247_PROJECT}-realtime
    depends_on: !override
      postgres:
        condition: service_healthy
      mongo-init:
        condition: service_completed_successfully
YML
}
mc_dc() { dc -f "${ROOT}/${LIVE_OVERLAY}" -f "${WORK}/rename.yml" -f "${WORK}/clients.yml" "$@"; }

mc_boot() {
  mc_clients_file
  ENGINE_TLS_MONGO_MODE=requireTLS mc_dc up -d --wait --wait-timeout 180 --no-build --pull missing \
    mongo-api realtime >"${WORK}/up.log" 2>&1 && return
  tail -5 "${WORK}/up.log" | mc_redact >&2
  local c
  for c in mongo mongo-init mongo-api realtime; do docker logs --tail 10 "${M247_PROJECT}-${c}" 2>&1 | mc_redact >&2 || true; done
  fail "mongo under requireTLS and its clients did not come up"
}
mc_health() { docker inspect -f '{{.State.Health.Status}}' "${M247_PROJECT}-$1"; }

mc_live_server() {
  local tls=(--tls --tlsCAFile /etc/engine-tls/ca.pem) logs
  ! mongosh_in mongo >/dev/null 2>&1 || fail "a plaintext mongosh connected under requireTLS"
  [[ "$(mongosh_in mongo "${tls[@]}")" == *'"mode":"requireTLS"'* ]] || fail "a verified --tls session failed"
  pass "plaintext mongosh refused; verified --tls session in, net.tls.mode = requireTLS"
  [[ "$(mc_health mongo)" == healthy ]] || fail "mongo is not healthy (the --tls healthcheck)"
  logs="$(docker logs "${M247_PROJECT}-mongo-init" 2>&1)"
  [[ "$(docker inspect -f '{{.State.ExitCode}}' "${M247_PROJECT}-mongo-init")" == 0 ]] || fail "mongo-init did not exit 0"
  grep -qF 'Node is PRIMARY' <<<"${logs}" || fail "mongo-init did not reach PRIMARY over --tls"
  pass "mongo healthy (--tls healthcheck); mongo-init exit 0, Node is PRIMARY over --tls"
}

mc_live_clients() {
  [[ "$(mc_health mongo-api)" == healthy ]] || fail "mongo-api (Node driver) is not healthy"
  pass "mongo-api (Node driver) healthy: its readiness pings mongo"
  # The Rust producer degrades instead of exiting: a broken DSN is healthy at 20 s and
  # unhealthy past its 30 s server selection (devil probe, 2026-10-30), hence 45 s.
  local started now logs
  started="$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "${M247_PROJECT}-realtime")" +%s)"
  now="$(date +%s)"
  ((now >= started + 45)) || sleep $((started + 45 - now))
  logs="$(docker logs "${M247_PROJECT}-realtime" 2>&1)"
  grep -qF 'MongoDB change stream started' <<<"${logs}" || fail "realtime did not open its mongo change stream"
  ! grep -qE 'Failed to open change stream|Change stream (error|ended)|MongoDB connect failed' <<<"${logs}" ||
    fail "realtime's mongo change stream failed or ended"
  docker exec "${M247_PROJECT}-realtime" /app/realtime-server --healthcheck >/dev/null 2>&1 || fail "realtime is unhealthy at 45 s"
  [[ "$(mc_health realtime)" == healthy ]] || fail "realtime is not healthy at 45 s"
  pass "realtime (Rust driver): MongoDB change stream started, healthy 45 s after start"
}

# The orchestrator's rendered DSN (M4's render, this stack's env), into MC_URI, never printed.
mc_orchestrator_uri() {
  MC_URI="$(mc_dc --profile '*' config --format json 2>/dev/null | jq -r '.services.orchestrator.environment.OUTBOX_MONGO_URL')"
  [[ "${MC_URI}" == mongodb://*@mongo:27017/*"${MC_QUERY}" ]] ||
    fail "the orchestrator's rendered OUTBOX_MONGO_URL is not the TLS default (an OUTBOX_MONGO_URL in .env?)"
}

# M7 fallback: booting the orchestrator needs pg-migrate and redis before its projector
# dials, so the probe links its mongo-driver (src/control-plane/go.mod) and dials its DSN.
mc_go_probe() {
  local image want out cp="${ROOT}/src/control-plane"
  mc_orchestrator_uri
  image="$(sed -n 's/^FROM \(golang:[^ ]*\) AS builder$/\1/p' "${cp}/Dockerfile")"
  want="$(awk '$1 == "go.mongodb.org/mongo-driver" {sub(/^v/, "", $2); print $2}' "${cp}/go.mod")"
  out="$(URI_OK="${MC_URI}" URI_SAN="${MC_URI/@mongo:27017/@${M247_PROJECT}-mongo:27017}" timeout 600 docker run --rm \
    --network "${NETWORK}" -e URI_OK -e URI_SAN -e GOTOOLCHAIN=local -e CGO_ENABLED=0 -e GOFLAGS=-mod=mod \
    ${M247_GOMODCACHE:+-v "${M247_GOMODCACHE}:/go/pkg/mod"} -v "${cp}/go.mod:/src/go.mod:ro" \
    -v "${cp}/go.sum:/src/go.sum:ro" -v "${ROOT}/scripts/verify/fixtures/m247-mongo-go-probe.go:/src/probe/main.go:ro" \
    -v "${ENGINE_TLS_MONGO_CERT_DIR}/ca.pem:${MC_CA}:ro" "${image}" sh -c 'cp -r /src /w && cd /w &&
      go build -o /tmp/probe ./probe && M247_MONGO_URI="$URI_OK" /tmp/probe &&
      ! M247_MONGO_URI="$URI_SAN" /tmp/probe' 2>&1)" || {
    tail -n 5 <<<"${out}" | mc_redact >&2
    fail "the orchestrator's mongo-driver did not connect on its DSN, or connected outside the SANs"
  }
  grep -qx "mongo-driver ${want}: mongo projector connected" <<<"${out}" || fail "the probe did not link mongo-driver ${want}"
  grep -q "mongo-driver ${want} refused: .*certificate" <<<"${out}" || fail "the SAN refusal was not a certificate error"
  pass "orchestrator DSN: mongo-driver ${want} connects verified; a name outside the SANs is refused"
}

# $1 the eval, verified: the database leg D round-trips.
mc_eval() { MONGO_EVAL="$1" mongosh_in mongo --tls --tlsCAFile /etc/engine-tls/ca.pem; }
mc_backup() { # $1 dump|restore
  (cd "${ROOT}" && env -u BACKUP_AGE_RECIPIENTS ENGINE_BACKUP_PREFIX="${M247_PROJECT}" timeout 300 \
    bash scripts/ops/engine-backup.sh "$1" mongo "${WORK}/rt.archive" --db m247rt) >"${WORK}/backup.log" 2>&1 || {
    tail -n 5 "${WORK}/backup.log" | mc_redact >&2
    fail "engine-backup $1 failed under requireTLS (M9)"
  }
}
mc_backup_roundtrip() {
  [[ "$(mc_eval 'db.getSiblingDB("m247rt").t.insertMany([{n: 1}, {n: 2}, {n: 3}]).acknowledged')" == true ]] ||
    fail "could not seed m247rt"
  mc_backup dump
  [[ "$(mc_eval 'db.getSiblingDB("m247rt").dropDatabase().ok')" == 1 ]] || fail "could not drop m247rt"
  mc_backup restore
  [[ "$(mc_eval 'db.getSiblingDB("m247rt").t.countDocuments()')" == 3 ]] || fail "the restore did not bring 3 docs back"
  pass "engine-backup dump + restore under requireTLS (--ssl --sslCAFile, --host localhost): 3 docs back"
}

mongo_clients_live_checks() {
  step "live D: requireTLS + every client kind verifies the engine cert (ADR 0025)"
  down
  mint_cert "${ENGINE_TLS_MONGO_CERT_DIR}"
  mc_boot
  mc_live_server
  mc_live_clients
  mc_go_probe
  mc_backup_roundtrip
  down
}
