#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m246-mount-descriptor.sh                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/29 20:30:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 04:30:00 by dlesieur         ###   ########.fr       #
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
# PATCH (ADR 0010) is routed on both hops, service-token gated, the revision
# trigger is in the migration and EnsureSchema, and no /connect consumer sends a
# literal pool version.
#
# Live (BAAS_VERIFY_LIVE=1, BAAS_KONG_URL, BAAS_TENANT_KEY): every listed mount's
# descriptor answers 200 with only the allowed keys and no DSN-shaped value, and
# its probe (ADR 0013) answers 200 with a normalised version and a closed TLS
# label, or 404 when the probe is off.

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

step "static: PATCH rotates through a revision (ADR 0010)"
need "${CP}/adapterregistry/handler.go" '"PATCH /databases/\{id\}", rt\.patch' "adapter-registry PATCH route missing"
[ "$(grep -c '"PATCH /v1/tenants/me/mounts/{mountId}", b.patchMount' "${CP}/tenants/builder.go")" = 1 ] ||
  fail "tenant-control must route PATCH once, in MountBuilder only (never the read-only MountMountList)"
patch=$(sed -n '/^func (rt \*routes) patch(/,/^}/p' "${CP}/adapterregistry/handler_patch.go")
grep -q 'validServiceToken' <<<"${patch}" || fail "PATCH must require the service token (it re-points live traffic)"
for f in "${ROOT}/scripts/migrations/postgresql/094_tenant_databases_revision.sql" "${CP}/adapterregistry/schema.go"; do
  need "$f" 'tenant_databases_bump_revision' "the revision trigger is not in ${f##*/} (migration and EnsureSchema must agree)"
done
QR="${ROOT}/src/apps/query-router/src/query"
! grep -nE "credentialVersion: '[^']*'" "${QR}/query.service.ts" "${QR}/schema.service.ts" ||
  fail "a /connect consumer still sends a literal credentialVersion; a rotated mount would keep its old pool"
need "${QR}/query.service.ts" 'credentialVersionFor\(' "query.service.ts does not derive the pool version from the revision"
need "${QR}/schema.service.ts" 'credentialVersionFor\(' "schema.service.ts does not derive the pool version from the revision"
pass "both hops routed, service-token gated, revision in both DDL paths, no literal pool version"

step "static: the live probe dials through the registry, flagged and masked (ADR 0013)"
DP="${ROOT}/src/data-plane-router/crates"
routes=$(sed -n '/if probe::enabled()/,/require_service_auth/p' "${DP}/data-plane-server/src/routes/mod.rs")
grep -q '"/v1/probe"' <<<"${routes}" || fail "/v1/probe must be registered under probe::enabled(), before require_service_auth"
probe_rs="${DP}/data-plane-server/src/routes/probe.rs"
need "${probe_rs}" 'get_or_create' "the probe must dial through the pool registry (devil G4 P1)"
need "${probe_rs}" 'Duration::from_secs\(3\)' "the probe lost its 3 s bound (P2)"
need "${probe_rs}" '"probe:\{\}"' "the probe lost its per-mount rate limit key (P10)"
need "${DP}/data-plane-pool/src/registry.rs" 'self\.0\.probe\(\)' "SharedPool does not forward probe(); every probe would read unknown (P3)"
need "${DP}/data-plane-pool/src/redis/pool.rs" 'TlsPosture::Plaintext' "redis must label itself plaintext: the crate has no TLS (P4)"
PS="${QR}/probe.service.ts"
need "${PS}" 'isStaticMount\(dbId\)' "the router probes static mounts, which match any tenant (P8)"
need "${PS}" "'platform'" "the router does not mask a platform mount's version (P9)"
need "${PS}" '\$\{revision' "the probe cache is not keyed on the credential revision"
! grep -n 'connection_string' <(sed -n '/ProbeResponse = {/,/};/p;/const value/,/;/p' "${PS}") ||
  fail "the probe response names the DSN"
pass "registry dial, 3 s bound, 1/s per mount, SharedPool forward, redis plaintext, static 404, platform mask"

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
print("%-12s %-9s %s tls=%s" % (d["engine"], d["location"], d.get("host") or d.get("file") or "-", d["tls"]))
' <<<"${out%$'\n'*}" || fail "${id}: descriptor carries more than its location"
done
step "live: the probe names a version and a TLS label, nothing else"
for id in ${ids}; do
  out=$(get "/query/v1/${id}/probe")
  code=${out##*$'\n'}
  case "${code}" in
  200) ;;
  404)
    printf '  ! %s: probe disabled or static (404)\n' "${id}"
    continue
    ;;
  *) fail "${id}: probe answered ${code}" ;;
  esac
  python3 -c '
import json, re, sys
d = json.loads(sys.stdin.read())
extra = set(d) - {"dbId","engine","server_version","tls","tls_version"}
if extra: sys.exit(f"keys {sorted(extra)}")
if not re.fullmatch(r"unknown|platform|[0-9]+(\.[0-9]+){0,3}", d["server_version"]): sys.exit("version not normalised")
if d["tls"] not in {"verified","encrypted","plaintext","not_applicable","unknown"}: sys.exit("tls label outside the closed set")
if d["engine"] == "redis" and d["tls"] != "plaintext": sys.exit("redis claims TLS it cannot have")
print("%-12s %-10s tls=%s" % (d["engine"], d["server_version"], d["tls"]))
' <<<"${out%$'\n'*}" || fail "${id}: probe answer breaks the contract"
done
printf '\033[32mm246 passed (static + live)\033[0m\n'
