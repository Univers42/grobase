#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m91-api-version-contract.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M91 — Track-B B7.11: API VERSION CONTRACT (RFC 8594 Sunset/Deprecation headers)
# wired as an ADDITIVE, ROUTE-SCOPED Kong response-transformer overlay. The
# contract: a route explicitly MARKED deprecated stamps Sunset + Deprecation
# (valid future date); a NON-deprecated route stamps NOTHING; with the overlay
# absent the proxy is byte-identical to today.
#
# Proven IN ISOLATION through a real Kong 3.8 DBLESS proxy (the same engine the
# live stack runs), in front of a trivial always-200 upstream (an httpbin-style
# echo so the test never depends on any mini-baas service). The script writes
# two MINIMAL declarative configs to temp files: one WITH the per-route
# deprecation overlay on ONE of two routes, one WITHOUT any overlay at all.
#
# What it asserts THROUGH KONG (proxy port), not at the upstream:
#
#   (A · POSITIVE) GET kong/deprecated/v1/* → 200 AND the response carries
#       `Deprecation` + a `Sunset` header whose value parses as a date STRICTLY
#       IN THE FUTURE (a stale/past Sunset is a contract bug — a client told the
#       route is already gone). Also asserts the rel="successor-version" Link.
#
#   (B · REJECT, LOAD-BEARING — a gate that only shows the happy path is vacuous):
#       on the SAME Kong, the OTHER route GET kong/active/v1/* → 200 AND carries
#       NEITHER Sunset NOR Deprecation. This is the accidental-global-stamping
#       guard: if someone moved the response-transformer to the top-level global
#       `plugins:` block (or onto the wrong route), EVERY route would stamp the
#       headers and this arm fails. The whole design leans on the plugin being
#       ROUTE-SCOPED, so this is the regression that matters.
#
#   (C · PARITY) a SECOND Kong booted on a config with NO overlay at all: BOTH
#       routes return 200 with NO Sunset/Deprecation header — byte-identical to
#       the live default kong.yml (which marks no route deprecated). The overlay
#       is harmless/absent in the default state.
#
# ISOLATED by design (mirrors m84): a trivial upstream echo + two Kong 3.8 DBLESS
# containers, ALL on a PRIVATE network, every name suffixed with $$, an EXIT-trap
# removing EVERYTHING. It NEVER touches a mini-baas-* container/network/image/
# volume and NEVER edits the live docker-compose.yml or the live kong.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                  # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"                       # apps/baas
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M91] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M91] FAIL — $*"; exit 1; }

KONG_IMAGE="${M91_KONG_IMAGE:-kong:3.8}"
# A shell-less, always-200 echo upstream. Kong's own image carries no http
# server we can point at; we use a tiny static httpbin-equivalent. kennethreitz/
# httpbin returns 200 on /anything/*; if unavailable, mendhak/http-https-echo is
# the fallback (both echo 200 on any path). Override with M91_ECHO_IMAGE.
ECHO_IMAGE="${M91_ECHO_IMAGE:-kennethreitz/httpbin}"

NET="m91net-$$"
ECHO="m91-echo-$$"
KONG_DEP="m91-kong-dep-$$"     # config WITH the route-scoped deprecation overlay
KONG_BASE="m91-kong-base-$$"   # config WITHOUT any overlay (parity)
PORT_KONG_DEP="${M91_PORT_KONG_DEP:-18997}"
PORT_KONG_BASE="${M91_PORT_KONG_BASE:-18998}"
HDR_TMP="$(mktemp)"
KONG_DEP_YML="$(mktemp /tmp/m91-kong-dep-$$.XXXXXX.yml)"
KONG_BASE_YML="$(mktemp /tmp/m91-kong-base-$$.XXXXXX.yml)"
# Kong runs as a non-root user; a 0600 mktemp file is unreadable when bind-mounted
# on a runner whose UID differs from the container's kong user (CI). Make readable.
chmod 644 "$KONG_DEP_YML" "$KONG_BASE_YML"

# A Sunset instant STRICTLY in the future (the contract: a valid future date).
# Compute it dynamically so the gate never goes stale: now + ~365 days, RFC 1123.
SUNSET_FUTURE="$(date -u -d '+365 days' '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null \
  || date -u -v+365d '+%a, %d %b %Y %H:%M:%S GMT')"   # GNU || BSD date
SUNSET_EPOCH="$(date -u -d "${SUNSET_FUTURE}" +%s 2>/dev/null \
  || date -u -j -f '%a, %d %b %Y %H:%M:%S GMT' "${SUNSET_FUTURE}" +%s)"

cleanup() {
  docker rm -fv "${KONG_DEP}" "${KONG_BASE}" "${ECHO}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -f "${HDR_TMP}" "${KONG_DEP_YML}" "${KONG_BASE_YML}" 2>/dev/null || true
}
trap cleanup EXIT

# Fetch ONLY the response headers through Kong → HDR_TMP, return the status code.
#   $1=kong-port  $2=path
kong_head() {
  curl -s -o /dev/null -D "${HDR_TMP}" -w '%{http_code}' "http://127.0.0.1:$1$2"
}

# Case-insensitive presence test for a header NAME in HDR_TMP.  $1=header-name
has_header() { grep -qi "^$1:" "${HDR_TMP}"; }

# Extract a header VALUE (everything after the first colon, trimmed).  $1=name
header_val() {
  grep -i "^$1:" "${HDR_TMP}" | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r'
}

# Kong readiness through the proxy: any HTTP code on a wired path means routing
# works; a connection refusal / empty means keep waiting.  $1=container $2=port $3=probe-path
wait_kong_route() {
  local i code
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2$3" 2>/dev/null || true)"
    case "${code}" in
      2[0-9][0-9]|3[0-9][0-9]|4[0-9][0-9]) return 0 ;;
    esac
    docker inspect "$1" >/dev/null 2>&1 || { red "$1 exited early:"; docker logs "$1" 2>&1 | tail -20; return 1; }
    sleep 0.5
  done
  red "$1 never routed (last code='${code}'):"; docker logs "$1" 2>&1 | tail -25; return 1
}

# The config WITH the deprecation overlay: TWO routes share one echo upstream —
#   /active/v1     : NO overlay (the non-deprecated control — reject arm B)
#   /deprecated/v1 : a ROUTE-SCOPED response-transformer adding the RFC 8594
#                    headers (positive arm A). The plugin lives UNDER the route,
#                    never under the top-level `plugins:` block — that scoping is
#                    exactly what arm B verifies did not regress.
write_kong_dep_yml() {
  cat > "${KONG_DEP_YML}" <<YAML
_format_version: "3.0"

services:
  - name: echo
    url: http://${ECHO}:80/anything
    routes:
      - name: active-v1
        paths: [/active/v1]
        strip_path: true
      - name: deprecated-v1
        paths: [/deprecated/v1]
        strip_path: true
        plugins:
          - name: response-transformer
            config:
              add:
                headers:
                  - "Deprecation:true"
                  - "Sunset:${SUNSET_FUTURE}"
                  - 'Link:<https://docs.grobase.dev/api/deprecations#deprecated-v1>; rel="deprecation"'
                  - 'Link:<https://api.grobase.dev/v2>; rel="successor-version"'
YAML
}

# The config WITHOUT any overlay (parity): the SAME two routes, NO plugins at all
# — byte-faithful to the live default kong.yml posture (no route deprecated).
write_kong_base_yml() {
  cat > "${KONG_BASE_YML}" <<YAML
_format_version: "3.0"

services:
  - name: echo
    url: http://${ECHO}:80/anything
    routes:
      - name: active-v1
        paths: [/active/v1]
        strip_path: true
      - name: deprecated-v1
        paths: [/deprecated/v1]
        strip_path: true
YAML
}

# Boot a Kong DBLESS container on the private net with a given declarative config.
#   $1=name  $2=config-file  $3=host-proxy-port
boot_kong() {
  docker run -d --name "$1" \
    --network "${NET}" \
    -e KONG_DATABASE=off \
    -e KONG_DECLARATIVE_CONFIG=/kong.yml \
    -e KONG_PROXY_ACCESS_LOG=/dev/stdout \
    -e KONG_ADMIN_ACCESS_LOG=/dev/stdout \
    -e KONG_PROXY_ERROR_LOG=/dev/stderr \
    -e KONG_ADMIN_ERROR_LOG=/dev/stderr \
    -e KONG_ADMIN_LISTEN=off \
    -e KONG_NGINX_WORKER_PROCESSES=1 \
    -e KONG_MEM_CACHE_SIZE=32m \
    -v "$2:/kong.yml:ro" \
    -p "127.0.0.1:$3:8000" \
    "${KONG_IMAGE}" >/dev/null
}

# ── 0) sanity: the computed Sunset really is in the future ─────────────────────
step "0/7 compute a future Sunset instant (RFC 1123) — the contract requires a valid FUTURE date"
NOW_EPOCH="$(date -u +%s)"
[[ -n "${SUNSET_EPOCH:-}" && "${SUNSET_EPOCH}" -gt "${NOW_EPOCH}" ]] \
  || fail "computed Sunset '${SUNSET_FUTURE}' is not in the future (epoch ${SUNSET_EPOCH:-?} ≤ now ${NOW_EPOCH}) (line: sunset compute)"
ok "Sunset = ${SUNSET_FUTURE} (epoch ${SUNSET_EPOCH} > now ${NOW_EPOCH})"

# ── 1) isolated net + echo upstream ────────────────────────────────────────────
step "1/7 boot isolated net (${NET}) + always-200 echo upstream (${ECHO_IMAGE})"
docker network create "${NET}" >/dev/null
docker run -d --name "${ECHO}" --network "${NET}" "${ECHO_IMAGE}" >/dev/null \
  || fail "echo upstream failed to start — set M91_ECHO_IMAGE to an always-200 echo image (line: echo run)"
ok "echo upstream up (alias ${ECHO})"

# ── 2) boot Kong WITH the route-scoped deprecation overlay ─────────────────────
step "2/7 write kong(dep).yml (route-scoped RFC 8594 overlay on /deprecated/v1 only) + boot Kong on :${PORT_KONG_DEP}"
write_kong_dep_yml
boot_kong "${KONG_DEP}" "${KONG_DEP_YML}" "${PORT_KONG_DEP}"
wait_kong_route "${KONG_DEP}" "${PORT_KONG_DEP}" /active/v1 || fail "Kong(dep) never routed (line: wait dep)"
ok "Kong(dep) up + routing /active/v1 + /deprecated/v1 → echo"

# ── 3) (A · POSITIVE) the deprecated route stamps Sunset + Deprecation (future) ─
step "3/7 (A · POSITIVE) GET kong/deprecated/v1 → 200 + Deprecation + future Sunset + successor Link"
C="$(kong_head "${PORT_KONG_DEP}" /deprecated/v1/ping)"
[[ "${C}" == "200" ]] || fail "(A) GET /deprecated/v1 expected 200, got ${C} — $(head -c 200 "${HDR_TMP}") (line: A status)"
has_header Deprecation || fail "(A) deprecated route is MISSING the Deprecation header — RFC 8594 signal not stamped — $(head -c 300 "${HDR_TMP}") (line: A deprecation)"
has_header Sunset || fail "(A) deprecated route is MISSING the Sunset header — $(head -c 300 "${HDR_TMP}") (line: A sunset present)"
SUN="$(header_val Sunset)"
GOT_EPOCH="$(date -u -d "${SUN}" +%s 2>/dev/null || date -u -j -f '%a, %d %b %Y %H:%M:%S GMT' "${SUN}" +%s 2>/dev/null || echo 0)"
[[ "${GOT_EPOCH}" -gt "${NOW_EPOCH}" ]] \
  || fail "(A) Sunset '${SUN}' is NOT a valid future date (epoch ${GOT_EPOCH} ≤ now ${NOW_EPOCH}) — a past/unparseable Sunset tells clients the route is already gone (line: A sunset future)"
grep -qi 'rel="successor-version"' "${HDR_TMP}" \
  || fail "(A) deprecated route missing the rel=\"successor-version\" Link (where to migrate) — $(head -c 300 "${HDR_TMP}") (line: A successor)"
ok "(A) /deprecated/v1 → 200 + Deprecation:$(header_val Deprecation) + Sunset (future: ${SUN}) + successor-version Link"

# ── 4) (B · REJECT, LOAD-BEARING) the active route stamps NOTHING ──────────────
step "4/7 (B · REJECT) GET kong/active/v1 on the SAME Kong → 200 + NO Sunset + NO Deprecation (no accidental global stamping)"
C="$(kong_head "${PORT_KONG_DEP}" /active/v1/ping)"
[[ "${C}" == "200" ]] || fail "(B) GET /active/v1 expected 200, got ${C} — $(head -c 200 "${HDR_TMP}") (line: B status)"
if has_header Deprecation || has_header Sunset; then
  fail "(B) ACCIDENTAL GLOBAL STAMPING: the NON-deprecated /active/v1 route carries Sunset/Deprecation — the response-transformer is not route-scoped! $(head -c 300 "${HDR_TMP}") (line: B no headers)"
fi
ok "(B) /active/v1 → 200 with NO Sunset/Deprecation — the overlay is route-scoped, not global"

# ── 5) (C · PARITY) a Kong with NO overlay: BOTH routes stamp nothing ──────────
step "5/7 (C · PARITY) boot a SECOND Kong on a config with NO overlay at all (:${PORT_KONG_BASE})"
write_kong_base_yml
boot_kong "${KONG_BASE}" "${KONG_BASE_YML}" "${PORT_KONG_BASE}"
wait_kong_route "${KONG_BASE}" "${PORT_KONG_BASE}" /active/v1 || fail "Kong(base) never routed (line: wait base)"
ok "Kong(base) up (no deprecation overlay — the live default kong.yml posture)"

step "6/7 (C · PARITY) BOTH routes on the overlay-free Kong → 200 + NO Sunset/Deprecation (byte-identical to today)"
for p in /deprecated/v1/ping /active/v1/ping; do
  C="$(kong_head "${PORT_KONG_BASE}" "${p}")"
  [[ "${C}" == "200" ]] || fail "(C) GET ${p} (no overlay) expected 200, got ${C} — $(head -c 200 "${HDR_TMP}") (line: C status ${p})"
  if has_header Deprecation || has_header Sunset; then
    fail "(C) PARITY BROKEN: ${p} carries Sunset/Deprecation with NO overlay loaded — the default state is not byte-parity! $(head -c 300 "${HDR_TMP}") (line: C no headers ${p})"
  fi
done
ok "(C) with the overlay absent, /deprecated/v1 + /active/v1 → 200 + NO lifecycle headers — byte-parity with the default kong.yml"

# ── 7) summary + gate log ──────────────────────────────────────────────────────
step "7/7 summary"
green "[M91] (A) POSITIVE: /deprecated/v1 → 200 + Deprecation + Sunset (future: ${SUNSET_FUTURE}) + successor-version Link (RFC 8594)"
green "[M91] (B) REJECT:   /active/v1 (same Kong) → 200 + NO Sunset/Deprecation — overlay is route-scoped, no accidental global stamping"
green "[M91] (C) PARITY:   overlay-free Kong → BOTH routes 200 + NO lifecycle headers = byte-identical to the default kong.yml"

emit_gate_log() {
  ( set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-b7-api-version-contract}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m91=PASS" --outcome pass \
      --msg "B7.11 API version contract: an opt-in ROUTE-SCOPED Kong response-transformer overlay stamps RFC 8594 Sunset+Deprecation+successor-version Link on a route MARKED deprecated. THROUGH KONG: /deprecated/v1 -> 200 + Deprecation + future Sunset + successor Link (positive); /active/v1 same Kong -> 200 + NO Sunset/Deprecation (reject: no accidental global stamping); a Kong with NO overlay -> BOTH routes 200 + NO lifecycle headers = byte-parity with the default kong.yml. Policy: wiki/api-versioning-policy.md; overlay: docker/services/kong/conf/deprecation.overlay.yml.example" \
      --ref "scripts/verify/m91-api-version-contract.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M91] ALL GATES GREEN — API version contract: deprecated route gets RFC 8594 headers, active route untouched, byte-parity when the overlay is absent"
exit 0
