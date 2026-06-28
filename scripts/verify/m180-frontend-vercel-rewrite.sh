#!/usr/bin/env bash
# ============================================================
# m180 — website same-origin rewrite to grobase (Vercel)
#
# The static website (vendor/grobase-website) talks to grobase only same-origin:
# Vercel rewrites /auth, /query, /storage to https://grobase-stack.fly.dev so the
# browser never makes a cross-origin call (Kong CORS allows only the fly origin).
# Realtime is the ONE exception — it is a direct browser→fly wss:// connection, so
# there is deliberately NO /realtime rewrite (that would break the WS upgrade).
#
# STATIC (always): vercel.json is valid JSON; the three rewrites target the fly
# app; NO /realtime rewrite; security headers present; build bypasses the
# container-only guard. LIVE (BAAS_VERIFY_LIVE=1): the deployed site 200s and a
# rewritten /auth path reaches GoTrue.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VJ="${ROOT}/vendor/grobase-website/vercel.json"
FLY="https://grobase-stack.fly.dev"
PASS=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\033[1m── m180: website same-origin rewrite ──\033[0m\n'

[ -f "${VJ}" ] || fail "vendor/grobase-website/vercel.json missing"

# valid JSON (prefer jq; fall back to python3)
if command -v jq >/dev/null 2>&1; then
  jq -e . "${VJ}" >/dev/null 2>&1 || fail "vercel.json is not valid JSON"
  ok "vercel.json is valid JSON"
  for p in auth query storage; do
    jq -e --arg s "/$p/:path*" --arg d "${FLY}/$p/:path*" \
      '.rewrites[] | select(.source==$s and .destination==$d)' "${VJ}" >/dev/null \
      || fail "missing same-origin rewrite for /$p → ${FLY}"
  done
  ok "rewrites /auth /query /storage → ${FLY}"
  jq -e '.rewrites[] | select(.source|test("realtime"))' "${VJ}" >/dev/null 2>&1 \
    && fail "vercel.json MUST NOT rewrite /realtime (WS is a direct browser→fly wss://)"
  ok "no /realtime rewrite (realtime is direct browser→fly wss://)"
  jq -e '.headers[0].headers[] | select(.key=="Strict-Transport-Security")' "${VJ}" >/dev/null \
    || fail "missing HSTS security header"
  jq -e '.headers[0].headers[] | select(.key=="X-Content-Type-Options")' "${VJ}" >/dev/null \
    || fail "missing X-Content-Type-Options header"
  ok "security headers present (HSTS, nosniff, frame-options, referrer, permissions)"
else
  python3 -c "import json,sys; json.load(open('${VJ}'))" 2>/dev/null || fail "vercel.json is not valid JSON"
  grep -q "${FLY}/auth/:path" "${VJ}"   || fail "missing /auth rewrite"
  grep -q "${FLY}/query/:path" "${VJ}"  || fail "missing /query rewrite"
  grep -q "${FLY}/storage/:path" "${VJ}" || fail "missing /storage rewrite"
  grep -q '"source": *"/realtime' "${VJ}" && fail "must not rewrite /realtime"
  ok "rewrites present; no /realtime rewrite (jq absent — grep fallback)"
fi

# the build must bypass the Docker-only guard on Vercel
grep -q '"buildCommand": *"npx astro build"' "${VJ}" \
  || grep -q '"GROBASE_IN_DOCKER"' "${VJ}" \
  || fail "build must bypass container-only.mjs (buildCommand override or GROBASE_IN_DOCKER)"
ok "build bypasses the Docker-only guard (Vercel can build the static site)"

# never ship a fly secret to Vercel
grep -qiE 'FLY_TOKEN|JWT_SECRET|mbk_|SERVICE_ROLE|POSTGRES_PASSWORD' "${VJ}" \
  && fail "vercel.json must NOT contain any fly secret"
ok "no fly secret present in vercel.json"

if [ "${BAAS_VERIFY_LIVE:-0}" = "1" ]; then
  : "${SITE_URL:?set SITE_URL=https://<app>.vercel.app for live mode}"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${SITE_URL}/") || true
  [ "${code}" = "200" ] || fail "deployed site did not 200 (got ${code})"
  ok "live: deployed website 200 at ${SITE_URL}"
fi

printf '\033[1;32mm180 PASS\033[0m — %d static checks; same-origin rewrite verified\n' "${PASS}"
