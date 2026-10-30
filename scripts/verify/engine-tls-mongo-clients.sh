#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    engine-tls-mongo-clients.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 18:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 18:00:00 by dlesieur         ###   ########.fr       #
#                                                                              #
# **************************************************************************** #
#
# Sourced by m247-engine-tls.sh; no m-prefix, so verify-all never runs it alone. G5 Mongo
# clients (ADR 0025, devil M1–M12): with mongo in ENGINE_TLS_ENGINES, every compose client
# dials mongo with tls=true&tlsCAFile against a CA-only file mount.
#
# Static (no stack): `docker compose --profile '*' config` with and without the mongo overlay,
# from a synthetic env, asserted by count and never by value: every mongodb:// string has
# tls=true, the CA file and a "/" before "?", and none has tlsInsecure or tlsAllowInvalid*;
# the DSNs are exactly M2's and each is its base value plus the TLS query; the cert directory
# is mounted on mongo only; mongo-init and the healthcheck differ from the base by the TLS
# flags alone; a bogus ENGINE_TLS_MONGO_MODE refuses before anything is copied.
#
# The ts-base anchor (_common.yml) passes MONGO_URI through from the host env, and config.env
# sets it to a plaintext mongodb://mongo:27017 for nine Node services. M2 does not restate it,
# so the census renders with MONGO_URI empty, and mc_passthrough proves none of those services
# reads it (engine-tls-mongo-readers.sh, devil N1–N8). Leg D lives in
# engine-tls-mongo-clients-live.sh.
#
# Caveat: the census sees compose only. A DSN built at runtime or set outside compose (pool
# mounts, the Trino catalog, seed scripts) is invisible to it, and a pass-through key other
# than MONGO_URI that a host env fills with a mongodb:// value is counted only if it renders.

MC_OVERLAY="orchestrators/compose/docker-compose.engine-tls-mongo.yml"
MC_CA=/etc/engine-tls-ca/ca.pem
MC_QUERY="tls=true&tlsCAFile=${MC_CA}"
MC_DSNS="ai-service.MONGO_URI analytics-service.MONGO_URI mongo-api.MONGO_URI orchestrator.OUTBOX_MONGO_URL outbox-relay.MONGO_URI outbox-relay.OUTBOX_MONGO_URL realtime.REALTIME_MONGO_URI"
MC_CA_MOUNTS="ai-service analytics-service mongo-api mongo-init orchestrator outbox-relay realtime"
# Every DSN as service.KEY, names only.
MC_JQ_DSNS='[.services | to_entries[] | .key as $s | (.value.environment // {}) | to_entries[]
  | select((.value // "") | tostring | test("mongodb://")) | "\($s).\(.key)"] | sort | join(" ")'

mc_redact() { sed -E 's#mongodb(\+srv)?://[^ "]*#mongodb://<redacted>#g'; }

# mc_render $1 out json, $2 OUTBOX_MONGO_URL to render with (empty: unset), rest compose -f flags.
# MONGO_URI is forced (compose reads it from .env even under --env-file: 16 DSNs instead of 7,
# measured 2026-10-30): empty by default, MC_MONGO_URI to see which services pass it through.
mc_render() {
  local out="$1" outbox="$2" pass_through=("MONGO_URI=${MC_MONGO_URI:-}")
  shift 2
  (cd "${ROOT}" && env -u OUTBOX_MONGO_URL -u ENGINE_TLS_MONGO_MODE -u ENGINE_TLS_MONGO_CERT_DIR "${pass_through[@]}" \
    ${outbox:+"OUTBOX_MONGO_URL=${outbox}"} timeout 120 docker compose --env-file "${MC_TMP}/floor.env" \
    -f docker-compose.yml "$@" --profile '*' config --format json) >"${out}" 2>"${MC_TMP}/render.err" ||
    fail "compose does not render ($*): $(tail -n 2 "${MC_TMP}/render.err" | mc_redact | tr '\n' ' ')"
}

# M1 M4 M12: the census of every mongodb:// string, counts only.
mc_census() {
  local q='[.. | strings | select(test("mongodb(\\+srv)?://"))] as $d | [($d | length),
    ([$d[] | select((contains("tls=true") and contains($ca)) | not)] | length),
    ([$d[] | select(test("tlsInsecure|tlsAllowInvalid"; "i"))] | length),
    ([$d[] | select(test("@mongo:27017/") | not)] | length)] | join(" ")'
  local base tls
  base="$(jq -r --arg ca "${MC_CA}" "${q}" "${MC_TMP}/base.json")"
  tls="$(jq -r --arg ca "${MC_CA}" "${q}" "${MC_TMP}/tls.json")"
  read -r total plain insecure noslash <<<"${tls}"
  ((total > 0)) || fail "the overlay render holds no mongodb:// DSN (parser drift?)"
  [[ "${base%% *}" == "${total}" ]] || fail "the overlay renders ${total} mongo DSNs, the base ${base%% *}"
  ((plain == 0)) || fail "${plain} of ${total} mongo DSNs lack tls=true and the CA file (M4)"
  ((insecure == 0)) || fail "${insecure} mongo DSNs carry tlsInsecure or tlsAllowInvalid* (M4)"
  ((noslash == 0)) || fail "${noslash} mongo DSNs have no / after mongo:27017 (M1)"
  [[ "$(cut -d' ' -f2 <<<"${base}")" == "${total}" ]] || fail "the base render already carries TLS (M12)"
  pass "${total} mongo DSNs: ${total} with tls=true + tlsCAFile and a / before ?, 0 insecure; base: 0 with TLS"
}

# M2: exactly these keys, each the base value plus the TLS query; the outbox two keep the override.
mc_restated() {
  [[ "$(jq -r "${MC_JQ_DSNS}" "${MC_TMP}/tls.json")" == "${MC_DSNS}" ]] || fail "the restated DSNs are not exactly M2's"
  [[ "$(jq -r "${MC_JQ_DSNS}" "${MC_TMP}/base.json")" == "${MC_DSNS}" ]] || fail "the base DSN set moved; restate it in ${MC_OVERLAY}"
  local drift
  drift="$(jq -nr --slurpfile b "${MC_TMP}/base.json" --slurpfile o "${MC_TMP}/tls.json" --arg q "${MC_QUERY}" \
    '[$o[0].services | to_entries[] | .key as $s | (.value.environment // {}) | to_entries[]
      | select((.value // "") | tostring | test("mongodb://"))
      | select((.value | rtrimstr($q) | rtrimstr("&") | rtrimstr("?") | rtrimstr("/")) != $b[0].services[$s].environment[.key])
      | "\($s).\(.key)"] | join(" ")')"
  [[ -z "${drift}" ]] || fail "not the base value plus the TLS query: ${drift}"
  [[ "$(grep -c 'OUTBOX_MONGO_URL:-mongodb://' "${ROOT}/${MC_OVERLAY}")" == 3 ]] ||
    fail "the outbox DSNs no longer default from \${OUTBOX_MONGO_URL:-…}"
  mc_render "${MC_TMP}/operator.json" "mongodb://operator.invalid:27017/x" -f "${MC_OVERLAY}"
  jq -e '[.services["outbox-relay"].environment.OUTBOX_MONGO_URL, .services["outbox-relay"].environment.MONGO_URI,
    .services.orchestrator.environment.OUTBOX_MONGO_URL] | all(. == "mongodb://operator.invalid:27017/x")' \
    "${MC_TMP}/operator.json" >/dev/null || fail "an operator OUTBOX_MONGO_URL is not used as set"
  pass "7 DSNs, each its base value + ${MC_QUERY}; an operator OUTBOX_MONGO_URL is used as set"
}

# M3: the cert directory on mongo only, the CA file read-only on each client.
mc_mounts() {
  local dir
  dir="$(jq -r '.services.mongo.volumes[] | select(.target == "/etc/engine-tls") | .source' "${MC_TMP}/tls.json")"
  [[ -n "${dir}" ]] || fail "mongo has no /etc/engine-tls mount"
  [[ "$(jq -r --arg d "${dir}" '[.services | to_entries[] | select([.value.volumes[]? | select(.source == $d)] | length > 0)
    | .key] | join(" ")' "${MC_TMP}/tls.json")" == mongo ]] || fail "the cert directory reaches a service other than mongo"
  [[ "$(jq '[.. | strings | select(contains("engine-key"))] | length' "${MC_TMP}/tls.json")" == 0 ]] ||
    fail "engine-key.pem is named in the render"
  [[ "$(jq -r --arg d "${dir}/ca.pem" --arg t "${MC_CA}" '[.services | to_entries[] | select([.value.volumes[]?
    | select(.type == "bind" and .source == $d and .target == $t and .read_only == true)] | length == 1)
    | .key] | sort | join(" ")' "${MC_TMP}/tls.json")" == "${MC_CA_MOUNTS}" ]] ||
    fail "the CA file is not mounted read-only on exactly: ${MC_CA_MOUNTS}"
  sed -n '/^x-mongo-ca:/,/^$/p' "${ROOT}/${MC_OVERLAY}" | grep -q 'create_host_path: false' ||
    fail "the CA file bind would be created root-owned"
  pass "cert directory on mongo only; ca.pem read-only on ${MC_CA_MOUNTS}"
}

# M6: mongo-init and the healthcheck are the base ones with the TLS flags added, nothing else.
mc_restated_scripts() {
  local init=" --tls --tlsCAFile ${MC_CA}" health=" --tls --tlsCAFile /run/engine-tls/ca.pem"
  jq -ne --slurpfile b "${MC_TMP}/base.json" --slurpfile o "${MC_TMP}/tls.json" --arg f "${init}" \
    '($o[0].services["mongo-init"].entrypoint | map(split($f) | join(""))) == $b[0].services["mongo-init"].entrypoint
     and ($o[0].services["mongo-init"].entrypoint | join("\n") | split($f) | length) == 3' >/dev/null ||
    fail "mongo-init differs from the base by more than --tls on both mongosh calls"
  jq -ne --slurpfile b "${MC_TMP}/base.json" --slurpfile o "${MC_TMP}/tls.json" --arg f "${health}" \
    '($o[0].services.mongo.healthcheck | .test |= map(split($f) | join(""))) == $b[0].services.mongo.healthcheck
     and ($o[0].services.mongo.healthcheck.test | join(" ") | contains("--host mongo" + $f))' >/dev/null ||
    fail "the mongo healthcheck differs from the base by more than --tls"
  pass "mongo-init (both mongosh calls) and the healthcheck = base + --tls --tlsCAFile, --host mongo kept"
}

# N5 N7: the services a host MONGO_URI reaches unrestated, from the render (a sentinel, so a
# host without .env still finds them), each mapped by its build APP to src/apps, none a reader.
mc_passthrough() {
  local sentinel="mongodb://mc-passthrough.invalid:27017/x" pairs names apps
  MC_MONGO_URI="${sentinel}" mc_render "${MC_TMP}/host.json" "" -f "${MC_OVERLAY}"
  pairs="$(jq -r --arg s "${sentinel}" '.services | to_entries[] | select(.value.environment.MONGO_URI == $s)
    | "\(.key)=\(.value.build.args.APP // "")"' "${MC_TMP}/host.json" | sort)"
  [[ -n "${pairs}" ]] || {
    pass "no service takes MONGO_URI from the host env"
    return
  }
  names="$(cut -d= -f1 <<<"${pairs}" | tr '\n' ' ')"
  mapfile -t apps < <(cut -d= -f2 <<<"${pairs}")
  mr_self_test "${MC_TMP}/n6"
  mongo_readers_census "${ROOT}/src" "${apps[@]}"
  pass "${MR_COUNT} pass-through, 0 readers: a host MONGO_URI reaches ${names% }, unread (M10)"
}

# The wrapper's stderr and status for engine $1, mode $2, in an empty environment.
mc_drop() {
  local rc=0 out
  out="$(env -i PATH="${PATH}" ENGINE_TLS_NAME="$1" ENGINE_TLS_UID=1 ENGINE_TLS_GID=1 ${2:+"ENGINE_TLS_MONGO_MODE=$2"} \
    sh "${ROOT}/infra/docker/services/engine-tls/drop-entrypoint.sh" true 2>&1 >/dev/null)" || rc=$?
  printf '%s %s' "${rc}" "${out}"
}

# M5: allowTLS by default, requireTLS on request, anything else refused before any copy.
mc_mode() {
  grep -qF 'ENGINE_TLS_MONGO_MODE: ${ENGINE_TLS_MONGO_MODE:-allowTLS}' "${ROOT}/${MC_OVERLAY}" ||
    fail "the overlay does not pass ENGINE_TLS_MONGO_MODE with the allowTLS default"
  [[ "$(jq -r '.services.mongo.environment.ENGINE_TLS_MONGO_MODE' "${MC_TMP}/tls.json")" == allowTLS ]] ||
    fail "mongo does not default to allowTLS"
  # Past the mode gate the wrapper reads /etc/engine-tls: on a host that has one, skip the run.
  [[ ! -e /etc/engine-tls ]] || {
    skip "ENGINE_TLS_MONGO_MODE refusal run (/etc/engine-tls exists on this host)"
    return
  }
  [[ "$(mc_drop mongo bogus)" == "1 mongo TLS: ENGINE_TLS_MONGO_MODE must be allowTLS or requireTLS" ]] ||
    fail "a bogus ENGINE_TLS_MONGO_MODE was not refused first"
  local m
  for m in "" allowTLS requireTLS; do
    [[ "$(mc_drop mongo "${m}")" == "1 mongo TLS is on but no engine cert in"* ]] || fail "mode '${m}' was refused"
  done
  [[ "$(mc_drop redis bogus)" == "1 redis TLS is on but no engine cert in"* ]] || fail "the mode gate reached redis"
  pass "ENGINE_TLS_MONGO_MODE: unset/allowTLS/requireTLS pass, bogus exits 1 before the cert copy, redis ignores it"
}

mongo_clients_static_checks() (
  step "static: mongo clients verify the engine cert (G5, ADR 0025)"
  command -v jq >/dev/null || fail "jq is required"
  MC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/m247-mc.XXXXXX")"
  trap 'rm -rf "${MC_TMP}"' EXIT
  # shellcheck source=../lib/lib-required-env.sh
  . "${ROOT}/scripts/lib/lib-required-env.sh"
  # shellcheck source=engine-tls-mongo-readers.sh
  . "${ROOT}/scripts/verify/engine-tls-mongo-readers.sh"
  required_env_floor m247-floor "${ROOT}" >"${MC_TMP}/floor.env"
  mc_render "${MC_TMP}/base.json" ""
  mc_render "${MC_TMP}/tls.json" "" -f "${MC_OVERLAY}"
  mc_census
  mc_restated
  mc_mounts
  mc_restated_scripts
  mc_mode
  mc_passthrough
)
