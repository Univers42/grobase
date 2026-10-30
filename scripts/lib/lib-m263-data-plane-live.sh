# shellcheck shell=bash
# lib-m263-data-plane-live.sh — the live legs of m263 (G5, ADR 0031, devil DT16): a scratch
# data plane serving :4011 and its TLS port :4012, a scratch postgres and tenant-control, and
# the Node runtime query-router runs on. Sourced by m263-data-plane-tls.sh after its helpers
# (ROOT, WORK, step, ok, fail). Containers and the network are named m263-<pid>-* and removed
# by live_cleanup; secrets reach docker and curl by name or from 0600 files, never on argv.
#
# Caveat: the query-router leg runs Node's https module in the image query-router is built
# on (M263_QR_IMAGE), not the built app, so it proves NODE_EXTRA_CA_CERTS reaches the global
# agent axios uses, not every query-router route. tenant-control's two clients both sit on
# Go's DefaultTransport; the relay proves the 65 s one, evict-verify the 8 s one.

# shellcheck source=service-auth.sh
. "${ROOT}/scripts/lib/service-auth.sh"

RUN="m263-$$"
NET="${RUN}-net" PG="${RUN}-pg" DPR="${RUN}-dpr" TCC="${RUN}-tc"
DPR_IMG="${M263_DPR_IMAGE:-${RUN}-dpr:scratch}"
TC_IMG="${M263_TC_IMAGE:-${RUN}-tc:scratch}"
QR_IMG="${M263_QR_IMAGE:-mirror.gcr.io/library/node:20-alpine}"
PLAIN_PORT="${M263_PORT_BASE:-18263}"
TLS_PORT=$((PLAIN_PORT + 1)) TC_PORT=$((PLAIN_PORT + 2))
ALIAS=data-plane-router-rust
CERTS="${WORK}/data-plane"
OUT="${WORK}/live.out"

live_cleanup() {
  docker rm -fv "${DPR}" "${TCC}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  [ -n "${M263_DPR_IMAGE:-}" ] || docker image rm -f "${DPR_IMG}" >/dev/null 2>&1 || true
  [ -n "${M263_TC_IMAGE:-}" ] || docker image rm -f "${TC_IMG}" >/dev/null 2>&1 || true
}

live_secrets() {
  export SERVICE_TOKEN_MODE=hmac
  INTERNAL_SERVICE_TOKEN="$(openssl rand -hex 32)" KONG_SERVICE_API_KEY="$(openssl rand -hex 32)"
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  DATABASE_URL="postgres://postgres:${POSTGRES_PASSWORD}@${PG}:5432/postgres?sslmode=disable"
  export INTERNAL_SERVICE_TOKEN KONG_SERVICE_API_KEY POSTGRES_PASSWORD DATABASE_URL
  (umask 077 && printf 'apikey: %s\n' "${KONG_SERVICE_API_KEY}" >"${WORK}/apikey.h")
}

# A scratch local CA, the data-plane cert from the real script (key → 65532, 0400), and an
# unrelated CA for the refusal legs.
live_mint() {
  mkdir -p "${WORK}/ca"
  TRACK_BINOCLE_CERT_DIR="${WORK}/ca" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
    sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null || fail "the scratch local CA was not minted"
  TRACK_BINOCLE_CERT_DIR="${WORK}/ca" ENGINE_TLS_CERT_DIR="${CERTS}" \
    sh "${ROOT}/scripts/certs/generate-engine-cert.sh" data-plane >/dev/null || fail "generate-engine-cert.sh data-plane failed"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=m263-other-ca \
    -keyout "${WORK}/other-ca-key.pem" -out "${WORK}/other-ca.pem" 2>/dev/null || fail "openssl could not mint the other CA"
}

live_images() {
  [ -n "${M263_DPR_IMAGE:-}" ] || docker build -q -t "${DPR_IMG}" "${ROOT}/src/data-plane-router" >/dev/null
  [ -n "${M263_TC_IMAGE:-}" ] || docker build -q -t "${TC_IMG}" --build-arg APP=tenant-control \
    --build-arg PORT=3022 "${ROOT}/src/control-plane" >/dev/null
}

# live_wait <url> <container> — until <url> answers 2xx, or the container dies.
live_wait() {
  for _ in $(seq 1 120); do
    curl -fsS -o /dev/null "$1" 2>/dev/null && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$2" 2>/dev/null)" = true ] || break
    sleep 0.5
  done
  docker logs "$2" 2>&1 | tail -15 >&2
  return 1
}

psql_c() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "${PG}" psql -U postgres -qtAc "$1"; }
has_table() { [ "$(psql_c "select count(*) from pg_tables where tablename = '$1'")" = 1 ]; }

# Postgres with the two tables tenant-control's boot check and RevokeKey read.
live_boot_pg() {
  docker network create "${NET}" >/dev/null
  docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD postgres:16-alpine >/dev/null
  for _ in $(seq 1 80); do
    [ "$(docker logs "${PG}" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] && break
    sleep 0.5
  done
  psql_c "create table public.tenants (id text primary key, slug text unique, name text, plan text);
    create table public.tenant_api_keys (id uuid primary key, tenant_id text, revoked_at timestamptz);
    insert into public.tenants values ('t-m263', 'm263', 'm263', 'free')" >/dev/null ||
    fail "scratch postgres never took the stand-in tables"
}

live_boot_dpr() {
  docker run -d --name "${DPR}" --network "${NET}" --network-alias "${ALIAS}" \
    -e RUST_LOG=info,data_plane_server::tls_listener=debug -e DATA_PLANE_ROUTER_PRODUCT_MODE=enabled \
    -e SERVICE_TOKEN_MODE -e INTERNAL_SERVICE_TOKEN -e DATA_PLANE_ROUTER_TLS_PORT=4012 \
    -e DATA_PLANE_ROUTER_TLS_CERT_FILE=/etc/data-plane-tls/engine.pem \
    -e DATA_PLANE_ROUTER_TLS_KEY_FILE=/etc/data-plane-tls/engine-key.pem -v "${CERTS}:/etc/data-plane-tls:ro" \
    -p "127.0.0.1:${PLAIN_PORT}:4011" -p "127.0.0.1:${TLS_PORT}:4012" "${DPR_IMG}" >/dev/null
  live_wait "http://127.0.0.1:${PLAIN_PORT}/v1/capabilities" "${DPR}" || fail "the data plane did not start with TLS on"
  local health=""
  for _ in $(seq 1 60); do
    health="$(docker inspect -f '{{.State.Health.Status}}' "${DPR}")"
    [ "${health}" = healthy ] && break
    sleep 1
  done
  [ "${health}" = healthy ] || fail "DT11: the router's healthcheck is ${health:-absent}, not healthy"
  ok "data plane up: :4011 answers, docker health is healthy with the TLS port checked (DT11)"
}

live_process_and_key() {
  [ "$(docker top "${DPR}" -eo pid,uid | awk 'NR > 1 { print $2 }' | sort -u)" = 65532 ] || fail "DT1: the router does not run as uid 65532"
  [ "$(stat -c '%a %u' "${CERTS}/engine-key.pem")" = "400 65532" ] || fail "DT1: the key is not 0400 owned by 65532"
  ok "DT1: the process runs as 65532 and reads a key that is 0400, owned by 65532"
}

# sclient [s_client args...] — a handshake against :4012 by the service name; output in OUT.
sclient() {
  timeout 10 openssl s_client -connect "127.0.0.1:${TLS_PORT}" -servername "${ALIAS}" "$@" </dev/null >"${OUT}" 2>&1
}

verified() { sclient -CAfile "$1" -verify_return_error -verify_hostname "$2" "${@:3}"; }

live_sclient() {
  verified "${CERTS}/ca.pem" "${ALIAS}" && grep -q 'Verify return code: 0 (ok)' "${OUT}" && grep -q 'TLSv1.3' "${OUT}" ||
    fail "s_client -verify_return_error -verify_hostname ${ALIAS} did not verify TLSv1.3: $(tail -3 "${OUT}")"
  ! verified "${WORK}/other-ca.pem" "${ALIAS}" || fail "a client trusting another CA was not refused"
  ! verified "${CERTS}/ca.pem" outside-the-sans.example || fail "a host name outside the SANs was not refused"
  ! sclient -CAfile "${CERTS}/ca.pem" -tls1_1 -cipher 'DEFAULT@SECLEVEL=0' || fail "TLS 1.1 was accepted"
  # rustls answers an h2-only offer with alert 120 (no_application_protocol), never h2.
  ! verified "${CERTS}/ca.pem" "${ALIAS}" -alpn h2 && grep -q 'alert number 120' "${OUT}" ||
    fail "DT3: an h2-only client was not refused with no_application_protocol"
  verified "${CERTS}/ca.pem" "${ALIAS}" -alpn h2,http/1.1 && grep -q 'ALPN protocol: http/1.1' "${OUT}" ||
    fail "DT3: a client offering h2 and http/1.1 did not get http/1.1"
  ok "s_client verifies TLSv1.3 by name; wrong CA, wrong name, TLS 1.1 and h2-only refused; ALPN http/1.1 (DT3)"
}

live_http() {
  local got
  got="$(curl -sS --cacert "${CERTS}/ca.pem" --resolve "${ALIAS}:${TLS_PORT}:127.0.0.1" -o /dev/null \
    -w '%{http_code} %{http_version}' "https://${ALIAS}:${TLS_PORT}/v1/capabilities")"
  [ "${got}" = "200 1.1" ] || fail "https on :4012 want '200 1.1', got '${got}'"
  got="$(curl -s --max-time 5 -o "${WORK}/plain" -w '%{http_code}' "http://127.0.0.1:${TLS_PORT}/v1/capabilities" || true)"
  [ "${got}" = 000 ] && ! grep -qs '^HTTP/' "${WORK}/plain" || fail "plain HTTP on :4012 got an HTTP answer (${got})"
  got="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PLAIN_PORT}/v1/capabilities")"
  [ "${got}" = 200 ] || fail "accept mode: :4011 want 200, got ${got}"
  docker logs "${DPR}" 2>&1 | grep 'handshake accepted' | grep -q 'TLSv1_3' || fail "DT17: no debug line for an accepted handshake"
  ! docker logs "${DPR}" 2>&1 | grep -q 'BEGIN\|PRIVATE KEY' || fail "DT17: the router logged PEM bytes"
  ok "https 200 over HTTP/1.1; plain HTTP on :4012 gets none; :4011 still 200; debug lines carry no key (DT17)"
}

handshakes() { docker logs "${DPR}" 2>&1 | grep -c 'handshake accepted' || true; }

# tc_boot <1|0> — tenant-control dialling https://…:4012, with or without the overlay's trust.
tc_boot() {
  local -a trust=()
  [ "$1" = 1 ] && trust=(-v "${CERTS}/ca.pem:/etc/data-plane-ca/ca.pem:ro" -e SSL_CERT_DIR=/etc/data-plane-ca:/etc/ssl/certs)
  docker rm -fv "${TCC}" >/dev/null 2>&1 || true
  docker run -d --name "${TCC}" --network "${NET}" -e TENANT_CONTROL_PORT=3022 -e SERVICE_TOKEN_MODE \
    -e INTERNAL_SERVICE_TOKEN -e DATABASE_URL -e KONG_SERVICE_API_KEY \
    -e RUST_DATA_PLANE_URL="https://${ALIAS}:4012" "${trust[@]}" -p "127.0.0.1:${TC_PORT}:3022" "${TC_IMG}" >/dev/null
  live_wait "http://127.0.0.1:${TC_PORT}/health/live" "${TCC}" || fail "scratch tenant-control did not start"
}

# relay <table> — status of the Kong admin relay (apikey arm) migrating <table>; body in OUT.
relay() {
  (umask 077 && printf '{"identity":{"tenant_id":"t1","user_id":"m263","roles":[],"scopes":[],"source":"service_token"},"mount":{"id":"m263-%s","tenant_id":"t1","engine":"postgresql","name":"db","credential_ref":{"provider":"inline","reference":"db","version":"1"},"inline_dsn":"postgres://postgres:%s@%s:5432/postgres"},"name":"%s","statements":["create table if not exists public.%s (id text primary key)"]}' \
    "$1" "${POSTGRES_PASSWORD}" "${PG}" "$1" "$1" >"${WORK}/relay.json")
  curl -s -o "${OUT}" -w '%{http_code}' -X POST "http://127.0.0.1:${TC_PORT}/v1/admin/migrate" \
    -H 'Content-Type: application/json' -H "@${WORK}/apikey.h" -d "@${WORK}/relay.json"
}

# revoke — status of a signed key revoke, which calls the data plane's evict-verify.
revoke() {
  local key path
  key="$(cat /proc/sys/kernel/random/uuid)"
  psql_c "insert into public.tenant_api_keys values ('${key}', 't-m263', null)" >/dev/null
  path="/v1/tenants/m263/keys/${key}"
  svc_auth_with "${INTERNAL_SERVICE_TOKEN}" DELETE "${path}" ""
  curl -s -o "${OUT}" -w '%{http_code}' -X DELETE "http://127.0.0.1:${TC_PORT}${path}" "${SVC_AUTH[@]}"
}

evict_failures() { docker logs "${TCC}" 2>&1 | grep -c 'evict-verify after key revoke failed' || true; }

live_tc_trusted() {
  local before got
  tc_boot 1
  before="$(handshakes)"
  got="$(relay m263_relay)"
  [ "${got}" = 200 ] && has_table m263_relay || fail "relay over TLS: want 200 + table, got ${got} — $(head -c 200 "${OUT}")"
  got="$(revoke)"
  [ "${got}" = 200 ] && [ "$(evict_failures)" = 0 ] || fail "revoke over TLS: want 200 and no evict failure, got ${got}"
  # Both clients share DefaultTransport, so the second call reuses the first's TLS session.
  [ "$(handshakes)" -gt "${before}" ] || fail "tenant-control's calls did not arrive over TLS"
  ok "tenant-control: Kong relay (65 s client) and revoke → evict-verify (8 s client) over verified TLS"
}

live_tc_untrusted() {
  local got
  tc_boot 0
  got="$(relay m263_relay_untrusted)"
  [ "${got}" = 502 ] && ! has_table m263_relay_untrusted || fail "relay without the CA: want 502 and no table, got ${got}"
  docker logs "${TCC}" 2>&1 | grep -q 'certificate signed by unknown authority' || fail "the refusal does not name the CA"
  [ "$(revoke)" = 200 ] && [ "$(evict_failures)" = 1 ] || fail "revoke without the CA: want 200 and one evict failure"
  ok "without SSL_CERT_DIR: relay 502 with no table, evict-verify refused (unknown authority)"
}

# node_probe <1|0> — Node's https GET of :4012, with or without NODE_EXTRA_CA_CERTS.
node_probe() {
  local -a trust=()
  [ "$1" = 1 ] && trust=(-v "${CERTS}/ca.pem:/etc/data-plane-ca/ca.pem:ro" -e NODE_EXTRA_CA_CERTS=/etc/data-plane-ca/ca.pem)
  docker run --rm --network "${NET}" "${trust[@]}" --entrypoint node "${QR_IMG}" -e \
    "require('https').get('https://${ALIAS}:4012/v1/capabilities', r => { console.log(r.statusCode, r.httpVersion);
      process.exit(r.statusCode === 200 ? 0 : 1) }).on('error', e => { console.log(e.code); process.exit(2) })" >"${OUT}" 2>&1
}

live_node() {
  node_probe 1 && grep -qx '200 1.1' "${OUT}" || fail "Node with NODE_EXTRA_CA_CERTS: $(head -c 200 "${OUT}")"
  local rc=0
  node_probe 0 || rc=$?
  [ "${rc}" = 2 ] && grep -q 'CERT\|VERIFY\|SIGN' "${OUT}" || fail "Node without the CA was not refused: $(head -c 200 "${OUT}")"
  ok "query-router's Node: 200 over HTTP/1.1 with NODE_EXTRA_CA_CERTS, $(head -1 "${OUT}") without"
}

live_main() {
  step "live: mint certs, build images, boot postgres and the data plane with :4012"
  live_secrets
  live_mint
  live_images || fail "scratch image build failed"
  live_boot_pg
  live_boot_dpr
  step "live: the TLS port"
  live_process_and_key
  live_sclient
  live_http
  step "live: both callers over verified TLS, and refused without their trust knob"
  live_tc_trusted
  live_tc_untrusted
  live_node
}
