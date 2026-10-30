# shellcheck shell=bash
# lib-m262-minio-probes.sh — the per-runtime trust legs of gate m262 (ADR 0030 MH9, MH13):
# every client runtime that dials minio (Node, Go, mc, the JVM via trino, Kong) makes one
# verified request with the minio CA, is refused with an unrelated CA, and gets 400 over
# plaintext. Sourced after lib-m262-minio-live.sh (dc, boot, mc_sh, NET, MINIO, WORK).
#
# Caveat: the trino wrong-CA leg waits for the SDK's retries to give up (about 140 s, MH9);
# a slower host past M262_TRINO_WAIT (240 s) reads as a FAIL, never as a pass.

image_of() { jq -r --arg s "$1" '.services[$s].image' "${WORK}/base.json"; }

# node_probe CA URL — Node's fetch with NODE_EXTRA_CA_CERTS, in the storage-router image.
node_probe() {
  docker run --rm --network "${NET}" -v "$1:/m262/ca.pem:ro" -e NODE_EXTRA_CA_CERTS=/m262/ca.pem \
    --entrypoint node "$(image_of storage-router)" -e 'fetch(process.argv[1])
      .then((r) => console.log("status=" + r.status))
      .catch((e) => console.log("error=" + ((e.cause && e.cause.code) || e.message)))' "$2"
}

# go_probe CA URL... — Go's default client with SSL_CERT_DIR=<the CA>:<the system roots>.
go_probe() {
  local ca="$1"
  shift
  docker run --rm --network "${NET}" -v "${ca}:/m262/ca/ca.pem:ro" -v "${PROBES}:/m262/probe:ro" \
    -e SSL_CERT_DIR=/m262/ca:/etc/ssl/certs -e GOCACHE=/tmp/go-cache -e GOFLAGS=-buildvcs=false \
    "${M262_GO_IMAGE:-mirror.gcr.io/library/golang:1.26.9}" go run /m262/probe/tls_probe.go "$@"
}

# expect LABEL GOT WANT_GLOB — one runtime answer against its expected shape.
expect() {
  # shellcheck disable=SC2053 # $3 is a glob on purpose
  [[ "$2" == $3 ]] || fail "$1: got '${2:0:160}', want $3"
}

live_runtimes() {
  step "live H: each runtime — minio CA verifies, an unrelated CA is refused, http answers 400 (MH13)"
  local right="${WORK}/minio/ca.pem" wrong="${WORK}/wrong/ca.pem" health=minio:9000/minio/health/live go refused
  refused="$(node_probe "${wrong}" "https://${health}")"
  expect "node, minio CA" "$(node_probe "${right}" "https://${health}")" status=200
  expect "node, wrong CA" "${refused}" error=UNABLE_TO_VERIFY_LEAF_SIGNATURE
  expect "node, http" "$(node_probe "${right}" "http://${health}")" status=400
  ok "node (NODE_EXTRA_CA_CERTS): 200 / ${refused} / 400"
  go="$(go_probe "${right}" "https://${health}" "http://${health}" | tr '\n' ' ')"
  expect "go, minio CA then http" "${go}" 'status=200 status=400 '
  expect "go, wrong CA" "$(go_probe "${wrong}" "https://${health}")" 'error=*x509*'
  ok "go (SSL_CERT_DIR): 200 / x509 refused / 400"
  local alias='mc alias set m "$0" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 && mc ls m >/dev/null 2>&1'
  mc_sh "${alias}" "${WORK}/minio" https://minio:9000 || fail "mc with the minio CA cannot list"
  mc_sh "${alias}" "${WORK}/wrong" https://minio:9000 && fail "mc trusted an unrelated CA"
  mc_sh "${alias}" "${WORK}/minio" http://minio:9000 && fail "mc listed minio over plaintext"
  ok "mc (certs/CAs): lists / refused / refused over http"
}

# trino_sql SQL... — Trino's statement protocol, from a Node container on the network,
# bounded by M262_TRINO_WAIT; live_cleanup removes the container a timeout leaves behind.
trino_sql() {
  timeout "${M262_TRINO_WAIT:-240}" docker run --rm --name "${PROJECT}-trino-q" --network "${NET}" \
    -v "${PROBES}:/m262/probe:ro" --entrypoint node \
    "$(image_of storage-router)" /m262/probe/trino-statement.cjs "$@"
}

trino_started() {
  local _
  for _ in $(seq 1 90); do
    docker exec "${PROJECT}-trino" curl -fsS http://localhost:8080/v1/info 2>/dev/null | grep -q '"starting":false' && return 0
    sleep 2
  done
  fail "trino never finished starting"
}

live_trino() {
  step "live I: trino (JVM, USE_SYSTEM_CA_CERTS) — rows over https; an unrelated CA → unhealthy and a cert-path failure (MH9)"
  boot "${OVERLAY}" trino
  trino_started
  local out
  out="$(trino_sql 'CREATE SCHEMA IF NOT EXISTS iceberg.m262t' 'CREATE TABLE IF NOT EXISTS iceberg.m262t.t (x int)' \
    'INSERT INTO iceberg.m262t.t VALUES (7)' 'SELECT x FROM iceberg.m262t.t' | tail -1)"
  expect "trino, minio CA" "${out}" 'FINISHED rows=[[][[]7[]][]]'
  ok "trino: CREATE/INSERT/SELECT over https → [[7]]"
  mkdir -p "${WORK}/wrong-dir" && cp "${WORK}/wrong/ca.pem" "${WORK}/wrong-dir/ca.pem"
  ENGINE_TLS_MINIO_CERT_DIR="${WORK}/wrong-dir" dc "${OVERLAY}" --profile storage up -d --no-deps --no-build \
    --force-recreate trino >"${WORK}/up-trino.log" 2>&1 || fail "trino did not recreate with the wrong CA"
  trino_started
  out="$(trino_sql 'SELECT x FROM iceberg.m262t.t' || echo TIMEOUT)"
  expect "trino, wrong CA" "${out}" 'FAILED cert-path=true *'
  local _ health=""
  for _ in $(seq 1 30); do
    health="$(docker inspect -f '{{.State.Health.Status}}' "${PROJECT}-trino")"
    [[ "${health}" == unhealthy ]] && break
    sleep 5
  done
  [[ "${health}" == unhealthy ]] || fail "trino with an unrelated CA reports ${health}, want unhealthy"
  ok "trino with an unrelated CA: query FAILED on SunCertPathBuilderException, container unhealthy"
}

# kong_probe CA LABEL — the scratch Kong with KONG_MINIO_CA_FILE; prints the storage status.
kong_probe() {
  local name="${PROJECT}-kong" status
  kong_scratch_start "${name}" "${M262_KONG_IMAGE:-$(image_of kong)}" "${NET}" \
    -e KONG_MINIO_CA_FILE=/etc/minio-ca/ca.pem -v "$1:/etc/minio-ca/ca.pem:ro" || fail "$2: kong did not start"
  if kong_scratch_wait "${name}" 2>"${WORK}/kong.err"; then
    status="$(kong_scratch_status "${name}" 8000 /storage/v1/minio/health/live 'apikey: scratch-anon')"
  else
    status="refused:$(docker logs "${name}" 2>&1 | grep -c 'holds a key')"
  fi
  docker rm -fv "${name}" >/dev/null
  printf '%s' "${status}"
}

live_kong() {
  step "live J: kong's storage hop — minio CA 200, unrelated CA 502, a key as CA refused (MH8)"
  # shellcheck source=lib-kong-scratch.sh
  . "${ROOT}/scripts/lib/lib-kong-scratch.sh"
  expect "kong, minio CA" "$(kong_probe "${WORK}/minio/ca.pem" "minio CA")" 200
  expect "kong, wrong CA" "$(kong_probe "${WORK}/wrong/ca.pem" "wrong CA")" 502
  expect "kong, key as CA" "$(kong_probe "${WORK}/minio/engine-key.pem" "key as CA")" 'refused:[1-9]*'
  ok "kong: 200 / 502 / render refuses a key"
}
