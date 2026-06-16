#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
GO_DIR="${BAAS_DIR}/go/control-plane"
COMPOSE_FILE="${BAAS_DIR}/docker-compose.yml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M19] FAIL: $*"; exit 1; }
step()  { cyan "[M19] ${*}"; }
pass()  { green "[M19] PASS: ${*}"; }

LIVE=0
for arg in "$@"; do
  [[ "${arg}" == "--live" ]] && LIVE=1
done

step "checking Go control-plane source layout"
for path in \
  "${GO_DIR}/go.mod" \
  "${GO_DIR}/Dockerfile" \
  "${GO_DIR}/cmd/adapter-registry/main.go" \
  "${GO_DIR}/internal/shared/postgres.go" \
  "${GO_DIR}/internal/shared/server.go" \
  "${GO_DIR}/internal/adapterregistry/crypto.go" \
  "${GO_DIR}/internal/adapterregistry/service.go" \
  "${GO_DIR}/internal/adapterregistry/handler.go"; do
  [[ -f "${path}" ]] || fail "missing ${path}"
done
pass "Go module, shared plumbing and adapter-registry exist"

step "checking control-plane boundary documentation"
DOC="wiki/architecture/typescript.md"
[[ -f "${DOC}" ]] || fail "missing ${DOC}"
grep -q "Go .*control plane" "${DOC}" || fail "${DOC} missing Go control-plane boundary"
grep -qi "deleted .*only after" "${DOC}" || fail "${DOC} missing deletion-gate rule"
pass "runtime split + deletion gate documented"

step "checking crypto stays byte-compatible with the Node CryptoService"
CRYPTO="${GO_DIR}/internal/adapterregistry/crypto.go"
grep -q "scryptN     = 16384" "${CRYPTO}" || fail "scrypt cost must match Node default (16384)"
grep -q "NewGCMWithNonceSize" "${CRYPTO}" || fail "must use 16-byte GCM nonce like Node"
grep -q "ivLength    = 16" "${CRYPTO}" || fail "IV length must be 16 to match Node"
pass "crypto parameters match the legacy format"

step "checking RLS tenant isolation is preserved"
grep -q "set_config('app.current_user_id'" "${GO_DIR}/internal/shared/postgres.go" \
  || fail "tenant queries must set app.current_user_id GUC"
pass "Go tenant queries reuse the existing RLS contract"

step "checking compose: Go adapter-registry is primary; TS retired post-cutover"
# Post-cutover: the TS adapter-registry was deleted after parity was proven
# (see scripts/verify/parity-probe.sh + adapter-registry-go cutover work).
# Compose must NOT declare the TS service anymore, AND consumers
# (query-router, schema-service, data-plane-router-rust) must point at the
# Go service by default.
if grep -q "^  adapter-registry:" "${COMPOSE_FILE}"; then
  fail "TS adapter-registry service should be deleted post-cutover"
fi
grep -q "^  adapter-registry-go:" "${COMPOSE_FILE}" || fail "Go adapter-registry service missing"
grep -qE "ADAPTER_REGISTRY_URL.*adapter-registry-go:3021" "${COMPOSE_FILE}" \
  || fail "compose default ADAPTER_REGISTRY_URL must point at the Go service"
pass "compose: Go adapter-registry is primary, TS retired"

step "running go vet + go test"
if command -v go >/dev/null 2>&1; then
  (cd "${GO_DIR}" && go mod tidy && go vet ./... && go test ./...)
else
  command -v docker >/dev/null 2>&1 || fail "go or docker is required for verification"
  docker run --rm \
    -v "${REPO_ROOT}/${GO_DIR}:/src" \
    -w /src \
    golang:1.25-bookworm \
    sh -c 'go mod tidy && go vet ./... && go test ./...'
fi
pass "go vet + go test passed"

if [[ ${LIVE} -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 || fail "docker required for --live mode"
  command -v curl >/dev/null 2>&1 || fail "curl required for --live mode"
  step "live: building + starting Go adapter-registry shadow service"
  docker compose -f "${COMPOSE_FILE}" --profile go-control-plane up -d --build --wait adapter-registry-go
  body=$(curl -fsS "http://127.0.0.1:${ADAPTER_REGISTRY_GO_PORT:-3021}/health/live") \
    || fail "live health endpoint failed"
  echo "${body}" | grep -q '"service":"adapter-registry"' || fail "health missing service tag"
  docker compose -f "${COMPOSE_FILE}" --profile go-control-plane stop adapter-registry-go >/dev/null
  docker compose -f "${COMPOSE_FILE}" --profile go-control-plane rm -f adapter-registry-go >/dev/null
  pass "live Go adapter-registry health endpoint works"
fi

green "[M19] OK - Go control-plane migration scaffold verified"
