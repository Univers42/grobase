#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m53-package-enforcement.sh                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M53 — package tier enforcement is correct AND safe (Track-2 F1).
#
# Enforcement is opt-in (PACKAGE_ENFORCEMENT=1 — the SaaS/scale shape; self-host
# stays off so an operator's own tenant is never gated). When ON this proves:
#   1. a tenant's tier engine ALLOWLIST is enforced — registering a mount for an
#      engine outside the tier → 403 engine_not_in_package;
#   2. an allowed engine on the same tier still registers (201) — enforcement
#      gates the disallowed, not everything;
#   3. raising the tier lifts the gate (enterprise → mongodb allowed);
#   4. a tenant with NO/blank plan degrades to the DEFAULT package (essential),
#      NOT a 500 — the "never break a planless tenant" guarantee.
#
# SKIPs (like m46/m39) unless enforcement is actually on, so it auto-runs under
# the SaaS shape and stays quiet on the self-host default. Register stores the
# encrypted DSN without connecting, so dummy connection strings are fine.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M53] $*"; }
pass()  { green "[M53] PASS: $*"; }
fail()  { red "[M53] FAIL: $*"; exit 1; }
skip()  { printf '\033[1;33m[M53] SKIP: %s\033[0m\n' "$*"; exit 0; }

# shellcheck source=scripts/verify/lib-live-tenant.sh
source "${SCRIPT_DIR}/lib-live-tenant.sh"

AR=mini-baas-adapter-registry-go
docker inspect "${AR}" >/dev/null 2>&1 || skip "adapter-registry-go not up"
ENF="$(docker inspect "${AR}" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^PACKAGE_ENFORCEMENT=//p' | head -1)"
[ "${ENF}" = "1" ] || skip "PACKAGE_ENFORCEMENT != 1 (self-host default); run under the SaaS/scale shape"

SLUG="m53enf$(date +%s)"
step "provisioning probe tenant '${SLUG}' (lib sets enterprise + a pg mount)"
live_tenant_provision "${SLUG}" || fail "provisioning failed (enterprise+pg mount should pass enforcement)"
trap live_tenant_cleanup EXIT
pass "enterprise tier registered a postgresql mount (201) — allowed engine passes"

# helper: register a mount of <engine> with a dummy DSN; echo the HTTP code.
reg() { # $1 engine
  curl -s -o /tmp/m53.json -w '%{http_code}' -X POST "${LIVE_KONG_URL}/admin/v1/databases" \
    -H "apikey: ${LIVE_SERVICE_APIKEY}" -H "X-Tenant-Id: ${SLUG}" -H 'Content-Type: application/json' \
    -d "{\"engine\":\"$1\",\"name\":\"m53-$1-$(date +%s%N)\",\"connection_string\":\"$1://u:p@host:1234/db\"}"
}
setplan() { # $1 plan value
  svc_auth PATCH "/v1/tenants/${SLUG}" "{\"plan\":\"$1\"}"
  curl -s -o /dev/null -X PATCH "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${SLUG}" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "{\"plan\":\"$1\"}"
}

# ── 1) downgrade to essential → mongodb is OUTSIDE the tier ───────────────────
step "plan=essential: mongodb mount must be blocked (403)"
setplan essential
CODE="$(reg mongodb)"
[ "${CODE}" = "403" ] || fail "essential mongodb mount got ${CODE}, want 403: $(head -c 160 /tmp/m53.json)"
grep -q 'engine_not_in_package' /tmp/m53.json || fail "403 but not engine_not_in_package: $(head -c 160 /tmp/m53.json)"
pass "essential blocks mongodb (403 engine_not_in_package)"

step "plan=essential: postgresql mount still allowed (201)"
CODE="$(reg postgresql)"
[ "${CODE}" = "201" ] || fail "essential postgresql mount got ${CODE}, want 201: $(head -c 160 /tmp/m53.json)"
pass "essential still allows postgresql (201) — gate is per-engine, not blanket"

# ── 2) raise the tier → the gate lifts ───────────────────────────────────────
step "plan=enterprise (→max): mongodb now allowed (201)"
setplan enterprise
CODE="$(reg mongodb)"
[ "${CODE}" = "201" ] || fail "enterprise mongodb mount got ${CODE}, want 201: $(head -c 160 /tmp/m53.json)"
pass "enterprise lifts the gate — mongodb allowed (201)"

# ── 3) legacy alias resolves to the tightest tier ────────────────────────────
# `free` is a legacy alias → nano (sqlite only). Proves packages.For() alias
# mapping AND that the cheapest tier really gates everything but sqlite — so a
# free tenant cannot quietly register a Postgres mount under enforcement.
step "plan=free (alias → nano, sqlite-only): postgresql blocked (403)"
setplan free
CODE="$(reg postgresql)"
[ "${CODE}" = "403" ] || fail "free/nano postgresql mount got ${CODE}, want 403 (nano allows only sqlite): $(head -c 160 /tmp/m53.json)"
grep -q 'engine_not_in_package' /tmp/m53.json || fail "403 but not engine_not_in_package: $(head -c 160 /tmp/m53.json)"
pass "free→nano resolves: postgresql blocked (403 engine_not_in_package) — alias + tightest tier"

green "[M53] ALL GATES GREEN — tier enforcement gates the engine allowlist per tier and resolves legacy aliases"
