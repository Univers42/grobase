# shellcheck shell=bash
# lib-m264-pg-clients-live.sh — the live legs of m264 (G5, ADR 0032, NP7/NP8/NP12, W1/W3–W5):
# the nine services, built from this tree, in a scratch compose project m264-<pid> over
# docker-compose.yml + engine-tls + pg-clients, beside its postgres (TLS, accept mode) and
# redis. Sourced by m264-pg-clients-tls.sh after its helpers (ROOT, WORK, OVERLAY,
# ENGINE_TLS_OVERLAY, CHECK, step, ok, fail). Every container is renamed m264-<pid>-<svc>, no
# port is published, and live_cleanup runs `down -v`. Probes are `docker exec -i <c> node -`
# with no -e (W3), so they see only the env compose rendered.
#
# Caveat: the probes build OutboxService and AuditService by hand from the image's dist, so
# they prove the pool each builds from the rendered env, not the controller → DI wiring that
# calls them (W6); the automations pool shares DATABASE_URL and is not driven. TLS per
# container is sampled from pg_stat_ssl every 0.5 s, so a backend living under 0.5 s can be
# missed (the probes hold theirs 1.5 s). minio and the services' other peers are not started
# (mongo is, plaintext, because mongo-api exits without it), so readiness is asserted only
# where it rests on Postgres, redis or mongo, and
# M264_REUSE_IMAGES=1 reuses the m264-local/*:reuse images without checking they are current.

PROJECT="m264-$$"
PG="${PROJECT}-postgres"
TENANT="${PROJECT}-tenant"
PG_CORE=(outbox-relay permission-engine schema-service gdpr-service newsletter-service session-service)
SOFT=(query-router mongo-api storage-router)
declare -A LIVE_PORT=(["query-router"]=4001 ["mongo-api"]=3010 ["storage-router"]=3040)
ENGINES=(postgres redis mongo)
ONESHOT=(mongo-keyfile mongo-init)
SSL_SELF='select ssl from pg_stat_ssl where pid = pg_backend_pid()'
IMG_TAG="${M264_REUSE_IMAGES:+reuse}"
IMG_TAG="${IMG_TAG:-${PROJECT}}"
PROBE="${ROOT}/scripts/verify/fixtures/m264-probe.js"
SAMPLES="${WORK}/ssl-samples"
SAMPLER=""
SSL_SQL="select a.client_addr, s.ssl, coalesce(s.version, '') from pg_stat_ssl s
  join pg_stat_activity a using (pid) where a.client_addr is not null"

ldc() {
  docker compose -p "${PROJECT}" --project-directory "${ROOT}" -f "${ROOT}/docker-compose.yml" \
    -f "${ROOT}/${ENGINE_TLS_OVERLAY}" -f "${ROOT}/${OVERLAY}" -f "${WORK}/live.yml" --profile "*" "$@"
}

live_cleanup() {
  [ -z "${SAMPLER}" ] || kill "${SAMPLER}" 2>/dev/null || true
  docker rm -fv "${TENANT}" >/dev/null 2>&1 || true
  [ -f "${WORK}/live.yml" ] && ldc down -v --remove-orphans >/dev/null 2>&1
  [ -n "${M264_REUSE_IMAGES:-}" ] && return 0
  local s
  for s in "${PG_CORE[@]}" "${SOFT[@]}"; do
    docker image rm -f "m264-local/${s}:${IMG_TAG}" >/dev/null 2>&1 || true
  done
}

# Renames every started container and gives the nine local tags, so nothing collides with a
# running mini-baas-* stack or a shared ghcr :latest.
live_yml() {
  local s
  printf 'services:\n' >"${WORK}/live.yml"
  for s in "${ENGINES[@]}" "${ONESHOT[@]}" "${PG_CORE[@]}" "${SOFT[@]}"; do
    printf '  %s:\n    container_name: %s-%s\n    ports: !reset []\n' "${s}" "${PROJECT}" "${s}"
    [[ " ${ENGINES[*]} ${ONESHOT[*]} " == *" ${s} "* ]] ||
      printf '    image: m264-local/%s:%s\n    pull_policy: never\n' "${s}" "${IMG_TAG}"
  done >>"${WORK}/live.yml"
}

live_images() {
  if [ -n "${M264_REUSE_IMAGES:-}" ] && docker image inspect "m264-local/query-router:reuse" >/dev/null 2>&1; then
    return 0
  fi
  ldc build -q "${PG_CORE[@]}" "${SOFT[@]}" >"${WORK}/build.log" 2>&1 ||
    fail "the nine images did not build from this tree: $(tail -n 5 "${WORK}/build.log")"
}

psql_c() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qtA "$@"; }
count() { psql_c -c "$1"; }

# The tables the probes write, from the real migrations (m131's apply pattern).
live_db() {
  local m
  ldc up -d --wait --no-deps --pull missing postgres redis >"${WORK}/engines.log" 2>&1 ||
    fail "postgres / redis did not become healthy: $(tail -n 5 "${WORK}/engines.log")"
  live_mongo
  psql_c <"${ROOT}/scripts/verify/fixtures/m264-prep.sql" >/dev/null || fail "m264-prep.sql did not apply"
  for m in 013_audit_log 015_outbox_events 022_outbox_saga_fields; do
    sed '/^#/d' "${ROOT}/scripts/migrations/postgresql/${m}.sql" | psql_c >/dev/null || fail "migration ${m} did not apply"
  done
  ok "postgres (engine TLS), redis and mongo healthy; audit_log and outbox_events from migrations 013/015/022"
}

# mongo-api exits without a writable replica set: the keyfile first, then mongo, then rs0.
live_mongo() {
  {
    ldc up --no-deps --pull missing --exit-code-from mongo-keyfile mongo-keyfile &&
      ldc up -d --wait --no-deps --pull missing mongo &&
      ldc up --no-deps --pull missing --exit-code-from mongo-init mongo-init
  } >"${WORK}/mongo.log" 2>&1 || fail "mongo did not become a writable rs0: $(tail -n 5 "${WORK}/mongo.log")"
}

# NP8: the server still accepts plaintext, so verify-full is the clients' side alone.
live_accept() {
  local ssl
  # hba asks TCP clients for a password; the container's own POSTGRES_PASSWORD answers it,
  # so the value never crosses the host's argv.
  local inner="PGPASSWORD=\"\${POSTGRES_PASSWORD}\" exec psql -qtA -c \"${SSL_SELF}\""
  inner+=" 'host=127.0.0.1 user=postgres dbname=postgres sslmode=disable'"
  ssl="$(docker exec "${PG}" sh -c "${inner}")" || fail "psql sslmode=disable was refused"
  [ "${ssl}" = f ] || fail "psql sslmode=disable came back ssl=${ssl}"
  ok "NP8: postgres still accepts sslmode=disable (accept mode, ssl=f)"
}

live_sampler() {
  : >"${SAMPLES}"
  while :; do
    psql_c -F ' ' -c "${SSL_SQL}" >>"${SAMPLES}" 2>/dev/null
    sleep 0.5
  done &
  SAMPLER=$!
}

health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${PROJECT}-$1" 2>/dev/null; }
alive() { docker exec "${PROJECT}-$1" wget -qO /dev/null "http://localhost:${LIVE_PORT[$1]}/health/live" 2>/dev/null; }

# wait_all PREDICATE SVC... — until PREDICATE passes for every SVC, 120 s at most.
wait_all() {
  local predicate="$1" s pending
  shift
  for _ in $(seq 1 120); do
    pending=""
    for s in "$@"; do "${predicate}" "${s}" || pending+=" ${s}"; done
    [ -z "${pending}" ] && return 0
    sleep 1
  done
  for s in ${pending}; do docker logs --tail 5 "${PROJECT}-${s}" 2>&1 | sed "s/^/  ${s}: /" >&2; done
  fail "${predicate} never passed for:${pending}"
}
is_healthy() { [ "$(health "$1")" = healthy ]; }

probe() { docker exec -i "${PROJECT}-$1" node - "${@:2}" <"${PROBE}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
probe_json() { probe "$@" | sed -n 's/^M264 //p' | tail -n 1; }

# One `up` per service: in a single `up` compose gates each service on its peers' depends_on
# health, and under the wrong CA permission-engine is meant to stay unhealthy. The wait_all
# predicates assert the state instead.
live_boot() {
  local s
  for s in "${PG_CORE[@]}" "${SOFT[@]}"; do
    ldc up -d --no-deps --no-build "$@" "${s}" >>"${WORK}/up.log" 2>&1 ||
      fail "${s} did not start: $(tail -n 5 "${WORK}/up.log")"
  done
}

live_env() {
  local s out
  for s in "${PG_CORE[@]}" "${SOFT[@]}"; do
    out="$(probe_json "${s}" env)"
    jq -e '.env | .suffixed and ([.pgsslmode, .pgsslrootcert, .extraCa, .audit] | any | not)' <<<"${out}" >/dev/null ||
      fail "${s}: env is $(jq -c .env <<<"${out}" 2>/dev/null || printf '%s' "${out}")"
  done
  ok "W3/NP3/NP5: all nine (exec without -e) see the suffixed DATABASE_URL, no PGSSL*, NODE_EXTRA_CA_CERTS or AUDIT_DATABASE_URL"
}

outbox_rows() { count "select count(*) from public.outbox_events where aggregate = 'm264_probe' and aggregate_id = '$1'"; }
audit_rows() { count "select count(*) from public.audit_log where resource = '$1'"; }

# W1/NP7: a mutating emitForQuery from query-router and an AuditService row from mongo-api and
# storage-router each land once, over the pool's own TLSv1.3 connection.
live_writes() {
  local id="m264-$$-good" s out
  out="$(probe_json query-router emit "${id}")"
  jq -e '.emitted and .ssl.ssl and .ssl.version == "TLSv1.3"' <<<"${out}" >/dev/null || fail "query-router emit: ${out}"
  [ "$(outbox_rows "${id}")" = 1 ] || fail "query-router emitted but outbox_events has $(outbox_rows "${id}") row(s)"
  for s in mongo-api storage-router; do
    out="$(probe_json "${s}" audit "${id}-${s}")"
    jq -e '.ssl.ssl and .ssl.version == "TLSv1.3"' <<<"${out}" >/dev/null || fail "${s} audit: ${out}"
    [ "$(audit_rows "${id}-${s}")" = 1 ] || fail "${s} audited but audit_log has $(audit_rows "${id}-${s}") row(s)"
  done
  ok "W1/NP7: emitForQuery(insert) → outbox_events +1; mongo-api and storage-router → audit_log +1 each, all over TLSv1.3"
}

ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PROJECT}-$1"; }

live_ssl_by_ip() {
  local s ip
  for s in "${PG_CORE[@]}" "${SOFT[@]}"; do
    ip="$(ip_of "${s}")"
    grep -qxF "${ip} t TLSv1.3" "${SAMPLES}" || fail "${s} (${ip}): pg_stat_ssl never sampled a TLSv1.3 backend"
    ! grep -q "^${ip//./\\.} f" "${SAMPLES}" || fail "${s} (${ip}): pg_stat_ssl sampled a plaintext backend"
  done
  ok "NP7: pg_stat_ssl, by container IP: all nine connected over TLSv1.3, none in plaintext"
}

# NP8: a tenant DSN without sslmode still dials plaintext from query-router's Node.
live_tenant() {
  local net out
  net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "${PG}")"
  docker run -d --name "${TENANT}" --network "${net}" -e POSTGRES_HOST_AUTH_METHOD=trust \
    mirror.gcr.io/library/postgres:16-alpine >/dev/null || fail "the scratch tenant postgres did not start"
  for _ in $(seq 1 60); do
    [ "$(docker logs "${TENANT}" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] && break
    sleep 0.5
  done
  out="$(probe_json query-router plain "postgres://postgres@${TENANT}:5432/postgres")"
  jq -e '.plain.ssl == false' <<<"${out}" >/dev/null || fail "tenant plaintext dial from query-router: ${out}"
  ok "NP8: a tenant DSN with no sslmode still connects in plaintext from query-router"
}

live_parse() {
  local out
  out="$(probe_json query-router parse)"
  jq -e '.pg == "8.20.0" and .pcs == "2.12.0" and .verified and .hasCa and .corruptedParam == "1?sslmode=verify-full"' \
    <<<"${out}" >/dev/null || fail "parse matrix: ${out}"
  ok "NP12: pg 8.20.0 + pg-connection-string 2.12.0 parse the suffix to verified TLS with ca.pem; ?a=1 → a=\"1?sslmode=verify-full\""
}

# Logs read whole first: under pipefail `docker logs | grep -q` fails on the SIGPIPE grep's
# early exit sends, so a refusal that is there reads as absent.
cert_refused() {
  local logs
  logs="$(docker logs "${PROJECT}-$1" 2>&1)"
  grep -qE 'UNABLE_TO_VERIFY_LEAF_SIGNATURE|SELF_SIGNED_CERT_IN_CHAIN|certificate' <<<"${logs}"
}
not_healthy() { [ "$(health "$1")" != healthy ]; }

# NP8/W4/W5: ca.pem swapped for an unrelated CA. The six PostgresModule services refuse at
# boot; query-router, mongo-api and storage-router stay up, and the outbox event and the audit
# row are lost with only a WARN.
live_wrong_ca() {
  local id="m264-$$-wrong" s out
  cp "${WORK}/engines/ca.pem" "${WORK}/good-ca.pem"
  cp "${WORK}/other-ca.pem" "${WORK}/engines/ca.pem"
  live_boot --force-recreate
  wait_all cert_refused "${PG_CORE[@]}"
  wait_all alive "${SOFT[@]}"
  for s in "${PG_CORE[@]}"; do not_healthy "${s}" || fail "${s} is healthy on an unrelated CA"; done
  ok "NP8: the six PostgresModule services log a certificate refusal and never turn healthy"
  out="$(probe_json query-router emit "${id}")"
  jq -e '(.emitted | not) and (.error | test("certificate"))' <<<"${out}" >/dev/null || fail "query-router emit on the wrong CA: ${out}"
  [ "$(outbox_rows "${id}")" = 0 ] || fail "an outbox event landed through an unrelated CA"
  for s in mongo-api storage-router; do
    out="$(probe "${s}" audit "${id}-${s}")"
    grep -q 'audit_log write failed.*certificate' <<<"${out}" || fail "${s}: no 'audit_log write failed' WARN: $(tail -n 3 <<<"${out}")"
    [ "$(audit_rows "${id}-${s}")" = 0 ] || fail "${s}: an audit row landed through an unrelated CA"
  done
  for s in "${SOFT[@]}"; do alive "${s}" || fail "${s} went down on the wrong CA"; done
  cp "${WORK}/good-ca.pem" "${WORK}/engines/ca.pem"
  ok "W4/W5: query-router, mongo-api, storage-router stay live; emit rejects, 'audit_log write failed' WARNs, 0 rows"
}

live_main() {
  step "live: preflight, nine images from this tree, postgres (TLS) + redis + mongo"
  bash "${ROOT}/${CHECK}" >/dev/null || fail "the preflight refused the scratch certs"
  live_yml
  live_images
  live_db
  live_accept
  live_sampler
  step "live: the nine on the CA that signed postgres"
  live_boot
  wait_all is_healthy "${PG_CORE[@]}"
  wait_all alive "${SOFT[@]}"
  ok "the six PostgresModule services are healthy; query-router, mongo-api, storage-router live"
  live_env
  live_writes
  live_ssl_by_ip
  live_tenant
  live_parse
  step "live: the nine on an unrelated CA"
  live_wrong_ca
}
