# shellcheck shell=bash
# lib-m262-minio-live.sh — the server and in-network client legs of gate m262 (ADR 0030),
# sourced by scripts/verify/m262-minio-https.sh after its static checks; uses its ROOT, WORK,
# PROJECT, OVERLAY, PROBES, step/ok/fail. Every container is "${PROJECT}-<service>" on
# "${PROJECT}_mini-baas", published nowhere, removed with its volumes by live_cleanup.
#
# Caveat: the refusal legs read the container's exit and log after up to 30 s; a host slow
# enough that minio has not exited non-zero by then reads as a FAIL, never as a pass.

NET="${PROJECT}_mini-baas"
MINIO="${PROJECT}-minio"
MINIO_IMAGE="${M262_IMAGE:-m262-local/grobase-minio:dev}"
LIVE_SERVICES=(minio storage-router minio-iceberg-init pg-backup iceberg-rest trino)
CA_IN_MINIO=/run/engine-tls/certs/CAs/ca.crt

# dc_argv [OVERLAY] — DC_ARGV: compose under this project with the rename (timeout can exec it).
dc_argv() {
  local -a files=(-f "${ROOT}/docker-compose.yml")
  [[ -n "${1:-}" ]] && files+=(-f "${ROOT}/$1")
  DC_ARGV=(docker compose -p "${PROJECT}" --project-directory "${ROOT}" "${files[@]}" -f "${WORK}/rename.yml")
}
# dc [OVERLAY] ARGS — DC_ARGV run with ARGS; the overlay is optional.
dc() {
  local with=""
  [[ "${1:-}" == *.yml ]] && with="$1" && shift
  dc_argv "${with}"
  "${DC_ARGV[@]}" "$@"
}

write_rename() {
  local s
  {
    echo services:
    for s in "${LIVE_SERVICES[@]}"; do
      printf '  %s:\n    container_name: %s-%s\n    ports: !reset []\n' "${s}" "${PROJECT}" "${s}"
      case "${s}" in
      minio) printf '    image: %s\n' "${MINIO_IMAGE}" ;;
      trino) printf '    depends_on: !reset {}\n' ;;
      esac
    done
  } >"${WORK}/rename.yml"
}

# mint — the engine cert under a throwaway CA (as m247), plus an unrelated CA for the wrong legs.
mint() {
  TRACK_BINOCLE_CERT_DIR="${WORK}" MINI_BAAS_WAF_TLS_GID=none GROBASE_PUBLIC_ADDRESSES='' \
    sh "${ROOT}/scripts/certs/generate-localhost-cert.sh" >/dev/null
  TRACK_BINOCLE_CERT_DIR="${WORK}" ENGINE_TLS_CERT_DIR="${WORK}/minio" \
    sh "${ROOT}/scripts/certs/generate-engine-cert.sh" minio >/dev/null
  mkdir -p "${WORK}/wrong" "${WORK}/empty"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=m262-wrong-ca \
    -keyout "${WORK}/wrong/key.pem" -out "${WORK}/wrong/ca.pem" 2>/dev/null
  export ENGINE_TLS_MINIO_CERT_DIR="${WORK}/minio"
}

ensure_image() {
  docker image inspect "${MINIO_IMAGE}" >/dev/null 2>&1 && return
  docker build -q -t "${MINIO_IMAGE}" "${ROOT}/infra/docker/services/minio" >/dev/null || fail "cannot build ${MINIO_IMAGE}"
}

# boot FILE|- SERVICE... — up --wait with the overlay FILE (or none), or fail with the last log lines.
boot() {
  local with="$1"
  shift
  [[ "${with}" == - ]] && with=""
  if ! dc ${with:+"${with}"} --profile storage up -d --wait --wait-timeout 240 --no-build "$@" >"${WORK}/up.log" 2>&1; then
    tail -5 "${WORK}/up.log" >&2
    docker logs --tail 10 "${MINIO}" >&2 2>&1 || true
    fail "$* did not become healthy"
  fi
}
in_minio() { docker exec "${MINIO}" "$@"; }
code() { in_minio curl -s -o /dev/null -w '%{http_code}' "$@" || true; }
curl_rc() { in_minio curl -s -o /dev/null "$@" && echo 0 || echo $?; }

leg_default() {
  step "live A: no overlay → minio still serves plaintext (MH2)"
  boot - minio
  [[ "$(code http://localhost:9000/minio/health/live)" == 200 ]] || fail "the image no longer starts plaintext by default"
  ok "default minio: http://localhost:9000 → 200"
  dc --profile '*' down -v >/dev/null 2>&1
}

leg_server() {
  step "live B: overlay → HTTPS only, key 600 uid 1001 on tmpfs (MH2–MH4, MH12)"
  boot "${OVERLAY}" minio
  local uid key left ip
  uid="$(in_minio awk '/^Uid:/ { print $2 }' /proc/1/status)"
  key="$(in_minio stat -c '%a %u' /run/engine-tls/certs/private.key)"
  left="$(in_minio ls /run/engine-tls)"
  [[ "${uid}" == 1001 && "${key}" == "600 1001" ]] || fail "PID 1 uid ${uid}, key ${key}: want 1001 and 600 1001"
  [[ "${left}" == *certs* && "${left}" != *key* ]] || fail "the tmpfs still holds the source key: ${left}"
  local https plain console cplain nocacert san
  https="$(code --cacert "${CA_IN_MINIO}" https://localhost:9000/minio/health/live)"
  plain="$(code http://localhost:9000/minio/health/live)"
  console="$(code --cacert "${CA_IN_MINIO}" https://localhost:9001/)"
  cplain="$(code http://localhost:9001/)"
  nocacert="$(curl_rc https://localhost:9000/minio/health/live)"
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${MINIO}" | awk '{ print $1 }')"
  san="$(curl_rc --cacert "${CA_IN_MINIO}" --resolve "m262-nope:9000:${ip}" https://m262-nope:9000/minio/health/live)"
  [[ "${https}/${plain}/${console}/${cplain}/${nocacert}/${san}" == 200/400/200/400/60/60 ]] ||
    fail "https ${https}, plain ${plain}, console ${console}/${cplain}, no CA rc ${nocacert}, SAN rc ${san}"
  ok "uid 1001, key 600 1001; :9000 https 200 / http 400; :9001 https 200 / http 400; no CA and a non-SAN name rc 60"
}

# refused LABEL WANT ENV... — minio under the overlay exits non-zero and logs WANT.
refused() {
  local label="$1" want="$2" _ state=""
  shift 2
  (
    for kv in "$@"; do export "${kv?}"; done
    dc "${OVERLAY}" --profile storage up -d --no-build minio >/dev/null 2>&1 || true
  )
  for _ in $(seq 1 30); do
    state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${MINIO}" 2>/dev/null || true)"
    [[ -n "${state}" && "${state##* }" != 0 ]] && break
    sleep 1
  done
  # restart: unless-stopped turns a refusal into "restarting <code>", never "exited".
  [[ -n "${state}" && "${state##* }" != 0 ]] || fail "${label}: minio did not refuse (${state})"
  docker logs "${MINIO}" >"${WORK}/refused.log" 2>&1 || true
  grep -q "${want}" "${WORK}/refused.log" || fail "${label}: the refusal does not say '${want}'"
  dc --profile '*' down -v >/dev/null 2>&1
  ok "${label}: minio exits ${state##* } naming '${want}'"
}

leg_refusals() {
  step "live C: refusals (MH10, MH3)"
  dc --profile '*' down -v >/dev/null 2>&1
  refused "S3_PUBLIC_ENDPOINT set" 'S3_PUBLIC_ENDPOINT is set' S3_PUBLIC_ENDPOINT=https://s3.example.invalid
  refused "no cert" 'generate-engine-cert.sh minio' ENGINE_TLS_MINIO_CERT_DIR="${WORK}/empty"
}

leg_clients() {
  step "live D: storage-router, iceberg-rest, mc-init, pg-backup over verified https (MH7)"
  boot "${OVERLAY}" minio storage-router iceberg-rest
  [[ "$(docker inspect -f '{{.State.ExitCode}}' "${PROJECT}-minio-iceberg-init")" == 0 ]] || fail "mc-init failed"
  [[ "$(docker logs "${PROJECT}-minio-iceberg-init" 2>&1 | grep -c 'bucket ready')" == 2 ]] || fail "mc-init made no buckets"
  docker exec "${PROJECT}-storage-router" node -e 'fetch("http://localhost:3040/health/ready").then(async (r) =>
    process.exit(r.status === 200 && /"s3":\s*"up"|s3.{0,20}up/.test(await r.text()) ? 0 : 1)).catch(() => process.exit(1))' ||
    fail "storage-router is not ready with s3 up"
  local ns table
  ns="$(docker exec "${PROJECT}-iceberg-rest" curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"namespace":["m262"]}' http://localhost:8181/v1/namespaces)"
  table="$(docker exec "${PROJECT}-iceberg-rest" curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"name":"t","schema":{"type":"struct","schema-id":0,"fields":[{"id":1,"name":"x","required":false,"type":"int"}]}}' \
    http://localhost:8181/v1/namespaces/m262/tables)"
  [[ "${ns}" == 200 && "${table}" == *'"metadata-location":"s3://iceberg/m262/t/metadata/'* ]] ||
    fail "iceberg-rest could not write table metadata to minio (namespace ${ns})"
  dc_argv "${OVERLAY}"
  timeout 120 "${DC_ARGV[@]}" run --rm --no-deps -T --entrypoint sh pg-backup -c \
    'mc alias set t "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc ls t >/dev/null &&
     test "$MINIO_ENDPOINT" = https://minio:9000' >"${WORK}/pg-backup.log" 2>&1 ||
    fail "pg-backup's mc cannot list minio over https: $(tail -c 300 "${WORK}/pg-backup.log")"
  ok "mc-init 2/2 buckets; storage-router ready (s3 up); iceberg metadata in s3://iceberg; pg-backup lists over https"
}

# mc_sh SCRIPT CA_DIR [ARG...] — sh -c SCRIPT ARG... in the grobase-mc image on the network,
# CA_DIR/ca.pem in mc's certs/CAs.
mc_sh() {
  local script="$1" ca="$2"
  shift 2
  docker run --rm -i --network "${NET}" -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD \
    -v "${ca}/ca.pem:/home/mc/.mc/certs/CAs/ca.crt:ro" --entrypoint sh "${MC_IMAGE}" -c "${script}" "$@"
}

# minio_login — the root login from the running minio into this shell's env, for mc_sh
# (the gate never sources .env; values are never printed).
minio_login() {
  MINIO_ROOT_USER="$(in_minio printenv MINIO_ROOT_USER)" MINIO_ROOT_PASSWORD="$(in_minio printenv MINIO_ROOT_PASSWORD)"
  export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
}

leg_presign() {
  step "live E: a URL signed against https://minio:9000 answers 200 to a client holding the CA (MH10)"
  local url
  minio_login
  url="$(printf 'm262' | mc_sh 'mc alias set l https://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null &&
    mc pipe l/iceberg/m262-presign.txt >/dev/null && mc share download --expire 10m l/iceberg/m262-presign.txt' "${WORK}/minio" |
    sed -n 's/^Share: //p')"
  [[ "${url}" == https://minio:9000/iceberg/m262-presign.txt\?* ]] || fail "mc share gave no internal https URL"
  [[ "$(in_minio curl -s --cacert "${CA_IN_MINIO}" "${url}")" == m262 ]] || fail "the presigned URL did not return the object"
  ok "presigned https://minio:9000/... → the object, verified against the CA"
}

leg_mounts() {
  step "live F: no client container mounts a key (MH6)"
  local ids leaks
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}")"
  # shellcheck disable=SC2086 # one id per word
  leaks="$(docker inspect ${ids} | jq --arg m "/${MINIO}" '[.[] | select(.Name != $m) | .Mounts[]
    | select(.Source | test("engine-key|ca-key|/minio$|/minio/$"))] | length')"
  [[ "${leaks}" == 0 ]] || fail "${leaks} client mounts expose the minio key or its directory"
  ok "$(wc -w <<<"${ids}") containers inspected; 0 client mounts expose engine-key.pem, *-ca-key.pem or the cert dir"
}

leg_hostscripts() {
  step "live G: phase9 and stack-health, lifted from the files (MH11)"
  local p9="${ROOT}/scripts/test/phase/phase9-storage-operations-test.sh" body
  minio_login
  export MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}"
  eval "$(awk '/^MC_IMAGE=/; /^MINIO_CA_PEM=/,/^MINIO_ENDPOINT=/; /^mc_cmd\(\)/,/^}/' "${p9}" | sed "s/mini-baas-minio/${MINIO}/g")"
  [[ "${MINIO_ENDPOINT}" == https://127.0.0.1:9000 ]] || fail "phase9 picked ${MINIO_ENDPOINT}"
  mc_cmd "mc mb --ignore-existing local/m262p9" >/dev/null && printf 'hello' | mc_cmd "mc pipe local/m262p9/o >/dev/null" &&
    [[ "$(mc_cmd 'mc cat local/m262p9/o')" == hello ]] && mc_cmd "mc rb --force local/m262p9 >/dev/null" ||
    fail "phase9's mc_cmd cannot mb/pipe/cat/rb over https"
  body="$(awk '/docker exec -i "\$PROJECT-minio" sh -c/,/"\$@"'"'"'$/' "${ROOT}/scripts/ops/stack-health-requests.sh" |
    sed 's/^ *docker exec -i "$PROJECT-minio" sh -c //')"
  printf 'user = "%s:%s"\n' "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" | eval "docker exec -i ${MINIO} sh -c ${body}" ||
    fail "stack-health's minio login fails over https"
  printf 'user = "%s:wrong-%s"\n' "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" | eval "docker exec -i ${MINIO} sh -c ${body}" 2>/dev/null &&
    fail "stack-health's minio login accepted a wrong secret"
  ok "phase9 mb/pipe/cat/rb over https; stack-health logs in over TLS and refuses a wrong secret"
}

live_cleanup() {
  docker rm -fv "${PROJECT}-kong" "${PROJECT}-trino-q" >/dev/null 2>&1 || true
  [[ -f "${WORK}/rename.yml" ]] && dc --profile '*' down -v --remove-orphans >/dev/null 2>&1 || true
}

live_main() {
  MC_IMAGE="${M262_MC_IMAGE:-$(jq -r '.services["minio-iceberg-init"].image' "${WORK}/base.json")}"
  write_rename
  mint
  ensure_image
  leg_default
  leg_refusals
  leg_server
  leg_clients
  leg_presign
  live_runtimes
  live_trino
  live_kong
  leg_hostscripts
  leg_mounts
}
