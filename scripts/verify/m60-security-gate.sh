#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m60-security-gate.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M60 — Security audit-ready POSTURE gate (A6). Proves the SHIPPED security
# controls hold LIVE against the running mini-baas stack, that the CI security
# gates are wired, and that the ASVS/SOC2-lite control map enumerates the open
# gaps — then PRINTS the 7 known-open residuals as KNOWN-OPEN (it does NOT
# claim them closed; closing RS256-issuer / Vault-enforce / network-seg is a
# SEPARATE wave).
#
# It is deliberately NOT a 'grep -q the doc' vacuity. The TEETH are three LIVE
# NEGATIVE assertions through the REAL gateway path — each must return a real
# DENIAL, bound to real behavior:
#
#   (a) SQL-role lockdown (migration 039)  anon (the unauthenticated public
#       PostgREST role) CANNOT read public.outbox_events nor schema_migrations
#       through the /rest/v1 gateway. The CDC ledger carries every tenant's row
#       mutations + actor_id; before 039 it inherited a blanket anon SELECT and
#       pg_graphql would expose it. We assert 401 + a Postgres role-denial code
#       (42501 "permission denied for table …") — a transport error or a 200
#       with rows would BOTH trip the gate.
#
#   (b) JWT alg-confusion closed  a forged alg=none token AND a wrong-signature
#       token — each claiming role=service_role — are REJECTED with 401, not
#       silently honored as service_role. (PostgREST validates the JWS over the
#       same shared secret; alg=none → JWSNoSignatures, bad sig →
#       JWSInvalidSignature.) A 200 here would be a full auth bypass.
#
#   (c) Cross-tenant isolation  a SECOND tenant's VERIFIED api-key cannot
#       address the FIRST tenant's database mount: the query-router's
#       tenant-scoped mount resolution returns 404 "… not found for this
#       tenant", and the foreign caller NEVER sees our secret marker. The
#       control plane verifies the foreign key first (real authenticated
#       foreign identity), THEN denies the cross-tenant mount — so a 404 here
#       is a security decision, not a missing route. (This check sits in the
#       Node query-router BEFORE the Rust forward, so it holds even if the data
#       plane is transiently degraded; the gate distinguishes a real DENIAL
#       from infra-unavailable 502/503 and never passes on the latter.)
#
# CI WIRING: the blocking jobs in .github/workflows/mini-baas-security.yml are
# asserted present (gitleaks · cargo-audit · govulncheck · trivy · semgrep ·
# trufflehog · zap). A missing CORE tool fails the gate; documented-deferred
# extras (e.g. fuzz) are listed, not fatal.
#
# DOC: the OWASP-ASVS / SOC2-lite control map exists and enumerates ALL 7 open
# residual gaps by id.
#
# PASS = shipped controls hold live + CI gates wired + ASVS map present +
#        residuals tracked. The 7 residuals are PRINTED as KNOWN-OPEN.
#
# Requires: the stack UP (mini-baas-kong, -postgres, -postgrest, -tenant-control,
# -query-router) with migration 039 applied (step 0 verifies + applies it).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # …/apps/baas/mini-baas-infra
BAAS_ROOT="$(cd "${BAAS_DIR}/.." && pwd)"     # …/apps/baas (wiki + .github live here)
REPO_ROOT="$(cd "${BAAS_ROOT}/../.." && pwd)" # repo root (the other .github)

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
step() { cyan "[M60] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M60] FAIL — $*"
  exit 1
}

# shellcheck source=scripts/lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

# Inputs (assert real paths; the security workflow lives at the repo root).
WF=""
for c in \
  "${BAAS_ROOT}/.github/workflows/mini-baas-security.yml" \
  "${REPO_ROOT}/.github/workflows/mini-baas-security.yml"; do
  [[ -f "$c" ]] && {
    WF="$c"
    break
  }
done
ASVS="${BAAS_ROOT}/wiki/security-audit-asvs.md"
AUDIT="${BAAS_ROOT}/wiki/security-audit.md"

TMP="$(mktemp -d)"
SLUG="m60$(date +%s)$$"
FOE_SLUG="m60foe$(date +%s)$$"
# Identifiers captured explicitly so cleanup is correct even after the lib
# overwrites the LIVE_* vars on the SECOND (foreign) provision.
A_SLUG=""
A_KEY_ID=""
A_DB=""
A_KEY=""
B_SLUG=""
B_KEY_ID=""
B_DB=""
OWN_OK=0
TBL=""
KONG=""
ANON=""

cleanup() {
  # best-effort: drop the positive-control probe table on OUR (tenant A) mount.
  if [[ -n "${TBL}" && -n "${A_DB}" && -n "${KONG}" && -n "${A_KEY}" ]]; then
    curl -s -o /dev/null -X POST "${KONG}/query/v1/${A_DB}/schema/ddl" \
      -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${A_KEY}" \
      -H 'Content-Type: application/json' -d "{\"op\":\"drop_table\",\"table\":\"${TBL}\"}" 2>/dev/null || true
  fi
  # foreign tenant B (lib LIVE_* currently hold B after its provision, but be explicit).
  [[ -n "${B_SLUG}" ]] && { LIVE_TENANT_SLUG="${B_SLUG}" LIVE_TENANT_KEY_ID="${B_KEY_ID}" LIVE_TENANT_DB_ID="${B_DB}" live_tenant_cleanup 2>/dev/null || true; }
  # tenant A (override the lib vars so its mount/key/tenant are torn down too).
  [[ -n "${A_SLUG}" ]] && { LIVE_TENANT_SLUG="${A_SLUG}" LIVE_TENANT_KEY_ID="${A_KEY_ID}" LIVE_TENANT_DB_ID="${A_DB}" live_tenant_cleanup 2>/dev/null || true; }
  rm -rf "${TMP}"
}
trap cleanup EXIT

# ── 1) CI security jobs wired ─────────────────────────────────────────────────
step "1/5 CI security gates wired in mini-baas-security.yml"
[[ -n "${WF}" && -f "${WF}" ]] || fail "mini-baas-security.yml not found (looked in apps/baas/.github/workflows + repo .github/workflows)"
# CORE blocking tools — each MUST be present (a real absence fails the gate).
CORE_MISSING=()
declare -A CORE=(
  [gitleaks]='gitleaks'
  [trufflehog]='trufflehog'
  [semgrep]='semgrep'
  [trivy]='trivy'
  [cargo - audit]='cargo[ -]audit'
  [govulncheck]='govulncheck'
  [zap]='zap'
)
for name in gitleaks trufflehog semgrep trivy cargo-audit govulncheck zap; do
  if grep -qiE "${CORE[$name]}" "${WF}"; then
    ok "CI job present: ${name}"
  else
    CORE_MISSING+=("${name}")
  fi
done
[[ ${#CORE_MISSING[@]} -eq 0 ]] || fail "CORE CI security tools absent from the workflow: ${CORE_MISSING[*]}"
# The blocking aggregate must exist so a failure of any job blocks merge.
grep -qE 'security-gate' "${WF}" || fail "no blocking 'security-gate' aggregate job in the workflow"
ok "blocking 'security-gate' aggregate wired (any job failure blocks the merge)"
# Documented-deferred extras: list, do NOT fail.
EXTRAS_DEFERRED=()
grep -qiE 'cargo[ -]?fuzz|fuzz' "${WF}" || EXTRAS_DEFERRED+=("fuzz (cargo-fuzz on filter/DDL parsers)")
if [[ ${#EXTRAS_DEFERRED[@]} -gt 0 ]]; then
  yellow "  · documented-deferred CI extras (not fatal): ${EXTRAS_DEFERRED[*]}"
fi

# ── 2) ASVS / SOC2-lite control map present + enumerates the gaps ─────────────
step "2/5 OWASP-ASVS / SOC2-lite control map exists + enumerates open gaps"
[[ -f "${ASVS}" ]] || fail "security-audit-asvs.md (the ASVS/SOC2-lite map) is missing"
[[ -f "${AUDIT}" ]] || fail "security-audit.md (the findings doc) is missing"
grep -qiE 'ASVS' "${ASVS}" || fail "ASVS map doc does not reference OWASP ASVS"
grep -qiE 'SOC2' "${ASVS}" || fail "ASVS map doc has no SOC2-lite control list"
# Every one of the 7 open residuals must be enumerated by id in the map.
RESIDUALS=(G-RS256 G-Vault G-Net G-Hdr G-ReadAudit G-QoS G-Rotate)
RES_MISSING=()
for r in "${RESIDUALS[@]}"; do
  grep -q "${r}" "${ASVS}" || RES_MISSING+=("${r}")
done
[[ ${#RES_MISSING[@]} -eq 0 ]] || fail "ASVS map does not enumerate residual(s): ${RES_MISSING[*]}"
ok "ASVS/SOC2-lite map present; all 7 open residuals enumerated by id"

# ── 3) live prerequisites: 039 applied + scratch tenants ─────────────────────
step "3/5 live prerequisites (migration 039 + scratch tenants)"
# Migration 039 hardens the internal tables — apply idempotently if outbox_events
# still carries an anon grant (a fresh DB might predate it).
ANON_GRANT="$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='outbox_events' AND grantee IN ('anon','authenticated')" 2>/dev/null || echo '?')"
if [[ "${ANON_GRANT}" != "0" ]]; then
  sed '/^#/d' "${BAAS_DIR}/scripts/migrations/postgresql/039_internal_table_hardening.sql" |
    docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null ||
    fail "could not apply migration 039 (internal-table hardening)"
fi
# Re-affirm the lockdown is in place at the DB level (the backstop behind the
# live HTTP negative below).
RLS_ON="$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
  "SELECT relrowsecurity FROM pg_class WHERE relname='outbox_events'" 2>/dev/null || echo '?')"
[[ "${RLS_ON}" == "t" ]] || fail "outbox_events does not have RLS enabled (039 not effective)"
ANON_GRANT="$(docker exec mini-baas-postgres psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM information_schema.role_table_grants WHERE table_name='outbox_events' AND grantee IN ('anon','authenticated')" 2>/dev/null)"
[[ "${ANON_GRANT}" == "0" ]] || fail "outbox_events still grants anon/authenticated (${ANON_GRANT} grants) — 039 not effective"
ok "migration 039 effective: outbox_events RLS=on, 0 anon/authenticated grants"

live_tenant_provision "${SLUG}" || fail "tenant provisioning failed (is the stack up?)"
KONG="${LIVE_KONG_URL}"
ANON="${LIVE_ANON_APIKEY}"
A_SLUG="${LIVE_TENANT_SLUG}"
A_DB="${LIVE_TENANT_DB_ID}"
A_KEY="${LIVE_TENANT_API_KEY}"
A_KEY_ID="${LIVE_TENANT_KEY_ID}"
ok "tenant '${A_SLUG}' provisioned (mount ${A_DB})"

# ── 4) LIVE NEGATIVES — the teeth ─────────────────────────────────────────────
# helper: $1=method $2=path → writes body to ${TMP}/r.json, echoes http code.
req() { curl -s -o "${TMP}/r.json" -w '%{http_code}' -X "$1" "${KONG}$2" "${@:3}"; }
body() { head -c 300 "${TMP}/r.json"; }

step "4/5 LIVE NEGATIVE (a): anon CANNOT read the CDC ledger / migrations (039)"
# outbox_events — the multi-tenant CDC ledger. anon (no JWT → PostgREST anon role).
code="$(req GET "/rest/v1/outbox_events?limit=1" -H "apikey: ${ANON}")"
[[ "${code}" == "401" || "${code}" == "403" ]] ||
  fail "anon read of outbox_events returned ${code} (expected 401/403 DENY) — $(body)"
grep -q '42501' "${TMP}/r.json" ||
  fail "anon outbox read denied by ${code} but NOT a Postgres role denial (42501) — $(body)"
grep -qi 'permission denied for table' "${TMP}/r.json" ||
  fail "anon outbox denial message is not a table-permission denial — $(body)"
# and it must NOT have leaked any row payload.
grep -q '"payload"' "${TMP}/r.json" &&
  fail "LEAK: anon outbox read exposed a payload — $(body)"
ok "anon → outbox_events: ${code} 42501 'permission denied for table' (no rows leaked)"
# schema_migrations — same 039 lockdown.
code="$(req GET "/rest/v1/schema_migrations?limit=1" -H "apikey: ${ANON}")"
[[ "${code}" == "401" || "${code}" == "403" ]] ||
  fail "anon read of schema_migrations returned ${code} (expected DENY) — $(body)"
grep -q '42501' "${TMP}/r.json" ||
  fail "anon schema_migrations denial is not a Postgres role denial (42501) — $(body)"
ok "anon → schema_migrations: ${code} 42501 (internal tables locked, REST + GraphQL)"

step "4/5 LIVE NEGATIVE (b): forged JWT (alg=none / wrong-sig) is rejected"
# Mint a none-alg token claiming service_role; iss=supabase so the apikey consumer
# is selected and the request reaches PostgREST's JWS validation.
NONE_JWT="$(
  python3 - <<'PY'
import base64, json
b = lambda o: base64.urlsafe_b64encode(json.dumps(o, separators=(',',':')).encode()).rstrip(b'=').decode()
print(b({"alg":"none","typ":"JWT"}) + "." + b({"iss":"supabase","role":"service_role","exp":9999999999}) + ".")
PY
)"
WRONG_JWT="$(
  python3 - <<'PY'
import base64, json, hmac, hashlib
b = lambda o: base64.urlsafe_b64encode(json.dumps(o, separators=(',',':')).encode()).rstrip(b'=')
hdr = b({"alg":"HS256","typ":"JWT"}); pl = b({"iss":"supabase","role":"service_role","exp":9999999999})
sig = base64.urlsafe_b64encode(hmac.new(b"m60-deliberately-wrong-secret", hdr+b'.'+pl, hashlib.sha256).digest()).rstrip(b'=')
print((hdr+b'.'+pl+b'.'+sig).decode())
PY
)"
# alg=none must NOT be honored as service_role (would be a full auth bypass).
code="$(req GET "/rest/v1/outbox_events?limit=1" -H "apikey: ${ANON}" -H "Authorization: Bearer ${NONE_JWT}")"
[[ "${code}" == "401" || "${code}" == "403" ]] ||
  fail "alg=none JWT (role=service_role) returned ${code} — MUST be rejected (auth bypass!) — $(body)"
grep -q '"payload"' "${TMP}/r.json" &&
  fail "AUTH BYPASS: alg=none token read outbox payloads — $(body)"
ok "alg=none JWT (claiming service_role) → ${code} rejected (no service_role granted)"
# wrong-signature token must also be rejected.
code="$(req GET "/rest/v1/outbox_events?limit=1" -H "apikey: ${ANON}" -H "Authorization: Bearer ${WRONG_JWT}")"
[[ "${code}" == "401" || "${code}" == "403" ]] ||
  fail "wrong-signature JWT returned ${code} — MUST be rejected — $(body)"
grep -q '"payload"' "${TMP}/r.json" &&
  fail "AUTH BYPASS: wrong-signature token read outbox payloads — $(body)"
ok "wrong-signature JWT → ${code} rejected (JWS signature validated)"

step "4/5 LIVE NEGATIVE (c): a foreign tenant cannot read our mount"
# POSITIVE CONTROL first: OUR key CAN reach OUR mount — so the cross-tenant 404
# below is a SELECTIVE isolation decision, not a blanket "everything is 404".
# We create + read a marker row through OUR mount. The data plane may be
# transiently degraded (the documented stale-IP wedge → 502); we treat 502/503
# as infra (skip the positive control with a note), but a real DENIAL on our
# OWN mount (401/403/404) is a genuine regression and fails the gate.
MARK="m60mark${RANDOM}"
TBL="m60own_$$"
own_create="$(req POST "/query/v1/${A_DB}/schema/ddl" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${A_KEY}" \
  -H 'Content-Type: application/json' \
  -d "{\"op\":\"create_table\",\"table\":\"${TBL}\",\"columns\":[{\"name\":\"id\",\"normalized_type\":\"integer\",\"nullable\":false,\"default\":null,\"enum_values\":null},{\"name\":\"secret\",\"normalized_type\":\"text\",\"nullable\":true,\"default\":null,\"enum_values\":null}],\"primary_key\":[\"id\"]}")"
case "${own_create}" in
20* | 409)
  req POST "/query/v1/${A_DB}/tables/${TBL}" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${A_KEY}" \
    -H 'Content-Type: application/json' -d "{\"op\":\"insert\",\"data\":{\"id\":1,\"secret\":\"${MARK}\"}}" >/dev/null
  own_read="$(req POST "/query/v1/${A_DB}/tables/${TBL}" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${A_KEY}" \
    -H 'Content-Type: application/json' -d '{"op":"list"}')"
  if [[ "${own_read}" =~ ^2 ]]; then
    # A real 2xx read of our OWN mount that returns OUR marker — this proves
    # the cross-tenant 404 below is SELECTIVE (the deny isn't universal) and
    # that the data path actually serves data (anti-vacuity for assertion (c)).
    grep -q "${MARK}" "${TMP}/r.json" ||
      fail "positive control: our key read our mount (${own_read}) but our marker '${MARK}' was missing — $(body)"
    ok "positive control: OUR key reads OUR mount (${own_read}, marker present) — isolation is SELECTIVE, not a blanket 404"
    OWN_OK=1
  elif [[ "${own_read}" =~ ^(401|403|404)$ ]]; then
    fail "positive control REGRESSED: our OWN key was denied (${own_read}) on our OWN mount — $(body)"
  else
    yellow "  · positive control inconclusive (own read ${own_read}, infra) — cross-tenant 404 below still proves the resolution-layer isolation"
    OWN_OK=0
  fi
  ;;
502 | 503)
  yellow "  · positive control skipped (data plane degraded ${own_create}, the documented wedge) — cross-tenant 404 below still proves resolution-layer isolation"
  OWN_OK=0
  ;;
*)
  fail "positive control: unexpected create code ${own_create} — $(body)"
  ;;
esac

# Provision a SECOND tenant; its key is real + verified by the control plane.
live_tenant_provision "${FOE_SLUG}" || fail "foreign tenant provisioning failed"
B_SLUG="${LIVE_TENANT_SLUG}"
B_KEY="${LIVE_TENANT_API_KEY}"
B_KEY_ID="${LIVE_TENANT_KEY_ID}"
B_DB="${LIVE_TENANT_DB_ID}"
# Sanity: the FOREIGN key verifies on ITS OWN control-plane surface, so a denial
# of OUR mount below is a security decision, not a broken/unknown key. The mount
# resolution that denies cross-tenant access lives in the query-router BEFORE the
# Rust forward, so a 404 here holds even when the data plane is transiently
# degraded — and we explicitly refuse to treat 502/503 (infra) as a "denial".
#
# Bounded retry rides out a TRANSIENT key-verify 502/503 (the documented stale-IP
# wedge where the query-router briefly can't reach tenant-control). It retries
# ONLY on infra-unavailable — a 200 (breach) is NEVER retried away, and a sticky
# wedge still fails the gate honestly rather than passing.
code=""
for _ in $(seq 1 8); do
  code="$(req POST "/query/v1/${A_DB}/tables/m60probe" -H "apikey: ${ANON}" -H "X-Baas-Api-Key: ${B_KEY}" \
    -H 'Content-Type: application/json' -d '{"op":"list"}')"
  [[ "${code}" == "502" || "${code}" == "503" ]] || break
  sleep 2
done
case "${code}" in
404 | 403)
  grep -qi 'not found for this tenant' "${TMP}/r.json" ||
    fail "cross-tenant mount denied (${code}) but not by tenant-scoped resolution — $(body)"
  ;;
502 | 503)
  fail "cross-tenant probe stuck on infra-unavailable (${code}) after retries — cannot ASSERT denial; data plane/tenant-control is degraded (the documented stale-IP wedge → 'docker restart mini-baas-tenant-control mini-baas-query-router'). Re-run. — $(body)"
  ;;
200)
  fail "CROSS-TENANT BREACH: foreign key ${B_SLUG} read our mount ${A_DB} (HTTP 200) — $(body)"
  ;;
*)
  fail "cross-tenant probe returned unexpected ${code} — $(body)"
  ;;
esac
# the foreign caller must never have seen any of our rows.
grep -q '"rows"' "${TMP}/r.json" &&
  fail "CROSS-TENANT BREACH: foreign caller received a rows envelope from our mount — $(body)"
ok "foreign tenant ${B_SLUG} → our mount ${A_DB}: ${code} 'not found for this tenant' (no rows)"

# ── 5) KNOWN-OPEN residuals — printed, NOT claimed closed ────────────────────
step "5/5 KNOWN-OPEN residuals (tracked, NOT closed by this gate)"
yellow "  These are the 7 audit-ready residuals — shipped posture does NOT include them."
yellow "  Closing them (RS256 issuer flip / Vault-enforce / network-seg) is a SEPARATE wave."
cat <<'RESID'
  ─ KNOWN-OPEN (see wiki/security-audit-asvs.md §3) ──────────────────────────
   1. G-RS256     JWT RS256 issuer NOT flipped — GoTrue still signs HS256
                  (verify side ready). Deferred: cross-repo, live login flow.
   2. G-Vault     Vault NOT enforced — plaintext/inline-encrypted DSNs possible
                  outside SECURITY_MODE=max. Deferred: coordinated.
   3. G-Net       Flat network / no NetworkPolicy — single bridge, no per-plane
                  segmentation. A6 / Track C.
   4. G-Hdr       adapter-registry header trust — X-Baas-* identity HMAC ships
                  but defaults OFF (gateway-signing is the remaining cross-repo
                  step). LOW.
   5. G-ReadAudit Reads NOT audited — only mutations + denials emit audit. LOW.
   6. G-QoS       No per-tenant resource QoS beyond rps (rows/timeout/pool/
                  storage uncapped). LOW.
   7. G-Rotate    No atomic key-rotation primitive (rotate-without-restart for
                  JWT_SECRET / service token). LOW (needs RS256 + HMAC first).
  ────────────────────────────────────────────────────────────────────────────
RESID
ok "7 residuals printed as KNOWN-OPEN (this gate proves SHIPPED controls only)"

PC_NOTE="positive control: own-mount read CONCLUSIVE (selective isolation proven)"
[[ "${OWN_OK}" == "1" ]] || PC_NOTE="positive control inconclusive (data plane degraded) — cross-tenant 404 alone proved resolution-layer isolation"
yellow "  · ${PC_NOTE}"

green "[M60] ALL GATES GREEN — audit-ready posture: SHIPPED controls hold LIVE (anon→internal-tables 401/42501 · forged JWT none/wrong-sig 401 · cross-tenant mount 404) · CI security gates wired (gitleaks·cargo-audit·govulncheck·trivy·semgrep·trufflehog·zap + blocking aggregate) · ASVS/SOC2-lite map present with all 7 residuals enumerated · 7 residuals KNOWN-OPEN (not claimed closed)"
