#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m246-mount-descriptor.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/29 20:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/29 20:30:00 by dlesieur         ###   ########.fr       #
#                                                                              #
# **************************************************************************** #
#
# Gate (G4): every mount names where its data lives (engine, host or file,
# database, requested TLS) and the descriptor never carries a credential.
#
# Static (no stack): both hops are routed (adapter-registry GET
# /databases/{id}/descriptor, tenant-control GET /v1/tenants/me/mounts/{id}/
# descriptor), the descriptor does not stamp last_healthy_at, and the Go tests
# that sweep a canary password across every DSN form exist (CI runs them).
#
# Live (BAAS_VERIFY_LIVE=1, BAAS_KONG_URL, BAAS_TENANT_KEY): every listed mount's
# descriptor answers 200 with only the allowed keys and no DSN-shaped value.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CP="${ROOT}/src/control-plane/internal"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}
step() { printf '\033[1m• %s\033[0m\n' "$*"; }
need() {
  grep -Eq "$2" "$1" || fail "$3 (expected /$2/ in ${1#"$ROOT"/})"
}

step "static: both hops are routed"
need "${CP}/adapterregistry/handler.go" '"GET /databases/\{id\}/descriptor", rt.descriptor' "adapter-registry route missing"
[ "$(grep -c '"GET /v1/tenants/me/mounts/{mountId}/descriptor", b.describeMount' "${CP}/tenants/builder.go")" = 2 ] ||
  fail "tenant-control must route the descriptor in MountBuilder and MountMountList"
need "${CP}/tenants/builder_mounts.go" 'isUUID\(id\)' "the mount id is not checked as a UUID before it joins the registry path"
pass "adapter-registry + tenant-control (builder and read-only list)"

step "static: reading the label is not a connection"
body=$(sed -n '/^func (s \*Service) Describe(/,/^}/p' "${CP}/adapterregistry/descriptor.go")
grep -q 'scanMountRow' <<<"${body}" || fail "Describe must read through scanMountRow"
! grep -Eq 'loadMountRow|last_healthy_at = now|s\.kms' <<<"${body}" || fail "Describe stamps last_healthy_at or calls the KMS"
need "${CP}/adapterregistry/descriptor_dsn.go" '^// Caveat:' "the descriptor heuristics carry no Caveat"
pass "no stamp, no KMS call, heuristics named"

step "static: the canary sweep exists"
need "${CP}/adapterregistry/descriptor_dsn_test.go" 'func TestDescriptorJSONCarriesNoCredential' "canary JSON sweep missing"
need "${CP}/tenants/builder_mounts_descriptor_test.go" 'escaped slash splices no path' "escaped-id test missing"
pass "go test ./... runs them in CI"

if [ "${BAAS_VERIFY_LIVE:-0}" != "1" ]; then
  printf '\n\033[33m! live descriptors skipped (set BAAS_VERIFY_LIVE=1, BAAS_KONG_URL, BAAS_TENANT_KEY)\033[0m\n'
  printf '\033[32mm246 static checks passed\033[0m\n'
  exit 0
fi

step "live: every mount describes itself, credential-free"
: "${BAAS_KONG_URL:?}" "${BAAS_TENANT_KEY:?}"
get() {
  curl -sk --max-time 20 -w '\n%{http_code}' -H "Authorization: Bearer ${BAAS_TENANT_KEY}" "${BAAS_KONG_URL}$1"
}
list=$(get /v1/tenants/me/mounts)
[ "${list##*$'\n'}" = 200 ] || fail "mount list answered ${list##*$'\n'}"
ids=$(python3 -c 'import json,sys; print(" ".join(m["id"] for m in json.loads(sys.stdin.read())))' <<<"${list%$'\n'*}")
[ -n "${ids}" ] || fail "the tenant has no mount to describe"
for id in ${ids}; do
  out=$(get "/v1/tenants/me/mounts/${id}/descriptor")
  [ "${out##*$'\n'}" = 200 ] || fail "${id}: descriptor answered ${out##*$'\n'}"
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
allowed = {"id","name","engine","isolation","credential_mode","location","host","port","file","database","tls","created_at","last_healthy_at"}
extra = set(d) - allowed
bad = [k for k, v in d.items() if isinstance(v, str) and ("://" in v or "@" in v or "password" in v.lower())]
if extra or bad: sys.exit(f"keys {sorted(extra)} / DSN-shaped {bad}")
print(f"{d[\"engine\"]:<12} {d[\"location\"]:<9} {d.get(\"host\") or d.get(\"file\") or \"-\"} tls={d[\"tls\"]}")
' <<<"${out%$'\n'*}" || fail "${id}: descriptor carries more than its location"
done
printf '\033[32mm246 passed (static + live)\033[0m\n'
