#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m186-functions-cold-invoke.sh — every cold invoke of a trivial function     #
#  must answer, not hang until the invoke timeout                              #
#                                                                              #
#  The cold path spawned a worker whose source did `await import(handler)`     #
#  and only THEN set self.onmessage, while the host posted the input the       #
#  moment the worker existed. When the message was dispatched before the       #
#  import resolved, nothing was listening: the input was dropped and the       #
#  invoke hung for exactly FUNCTIONS_INVOKE_TIMEOUT_MS, then answered 500      #
#  "timeout after 5000ms". Measured 2026-09-23: 12 of 40 cold invokes of an    #
#  echo function, on an idle machine, through no gateway at all. The offers    #
#  collection's Functions folder went red on it intermittently, which made     #
#  the whole suite BASELINE for the mutation runner.                           #
#                                                                              #
#  This gate builds the runtime from THIS tree, starts a throwaway copy with   #
#  the production cpus/mem, and runs N deploy-then-invoke cycles straight at   #
#  it. Every invoke must answer 200 with the echo. With a ~30% per-invoke      #
#  hang, 40 clean cycles by luck has probability 0.7^40 ≈ 6e-7.                #
#                                                                              #
#  Mutant: check out the previous server.ts (worker imports before wiring      #
#  onmessage) and this gate fails with timeouts.                               #
#                                                                              #
#  Its own image tag, container and volume, removed by an EXIT trap. It never  #
#  touches a mini-baas-* container.                                            #
# **************************************************************************** #
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CTX="${M186_CONTEXT:-${ROOT}/infra/docker/services/functions-runtime}"
N="${M186_CYCLES:-40}"
PORT="${M186_PORT:-3996}"
IMG="grobase-functions-runtime:m186-$$"
NAME="m186-fn-$$"
VOL="m186-data-$$"
cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
step() { cyan "[M186] $*"; }
ok() { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
fail() {
  printf '\033[0;31m[M186] FAIL — %s\033[0m\n' "$*" >&2
  exit 1
}
cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker volume rm -f "${VOL}" >/dev/null 2>&1 || true
  docker image rm -f "${IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "0/3 build the runtime from this tree"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker build -q -t "${IMG}" "${CTX}" >/dev/null || fail "could not build ${CTX}"
ok "image ${IMG}"

step "1/3 start a throwaway runtime (cpus 0.5, mem 256m, as in storage.yml)"
docker run -d --name "${NAME}" --cpus 0.5 --memory 256m -p "127.0.0.1:${PORT}:3060" \
  -e FUNCTIONS_DATA_DIR=/data -e FUNCTIONS_INVOKE_TIMEOUT_MS=5000 \
  -v "${VOL}:/data" "${IMG}" >/dev/null
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health/live" 2>/dev/null && break
  sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/health/live" || fail "runtime did not answer /health/live"
ok "runtime up on 127.0.0.1:${PORT}"

step "2/3 ${N} cold deploy+invoke cycles"
tenant="m186t$(date +%s)"
code='export default async function (input) { return { status: 200, body: { ok: true, echo: input.body } }; }'
hung=0
wrong=0
for i in $(seq 1 "${N}"); do
  fn="m186f${i}x$(date +%s%N | cut -c1-13)"
  body=$(printf '{"name":"%s","code":"%s"}' "${fn}" "${code}")
  dcode=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Baas-Tenant-Id: ${tenant}" \
    -H 'Content-Type: application/json' -d "${body}" "http://127.0.0.1:${PORT}/v1/functions")
  [ "${dcode}" = 201 ] || fail "deploy #${i} answered ${dcode}"
  out=$(curl -s -w '\n%{http_code} %{time_total}' -H "X-Baas-Tenant-Id: ${tenant}" \
    -H 'Content-Type: application/json' -d '{"hello":"world"}' \
    "http://127.0.0.1:${PORT}/v1/functions/${fn}/invoke")
  status=$(printf '%s' "${out}" | tail -n1)
  resp=$(printf '%s' "${out}" | sed '$d')
  case "${status}" in
  200\ *)
    printf '%s' "${resp}" | grep -q '"hello":"world"' || {
      wrong=$((wrong + 1))
      printf '  #%s 200 without the echo: %s\n' "${i}" "${resp:0:120}"
    }
    ;;
  *)
    hung=$((hung + 1))
    printf '  #%s %s: %s\n' "${i}" "${status}" "${resp:0:120}"
    ;;
  esac
done

step "3/3 verdict"
[ "${hung}" -eq 0 ] && [ "${wrong}" -eq 0 ] ||
  fail "${hung} of ${N} cold invokes failed or hung, ${wrong} answered without the echo"
ok "${N}/${N} cold invokes answered with the echo"
