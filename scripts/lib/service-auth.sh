#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    service-auth.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Bash half of the v1 HMAC service auth (audit O1) — the shell-script signer
# matching shared.ComputeServiceSignature (Go) / service_auth.rs (Rust) /
# service-auth.ts (TS). Sources so verify/seed scripts can keep talking to the
# control plane after the stack flips to SERVICE_TOKEN_MODE=hmac. Golden vector
# proven against the Go/Rust suites with token=test-token, ts=1700000000.
#
# Usage:
#   source scripts/lib/service-auth.sh
#   svc_auth_header_args POST /v1/keys/verify '{"key":"x"}'   # echoes curl -H args
#   curl ... $(svc_auth_header_args POST /v1/keys/verify "$BODY") ...
#
# In static mode (default / SERVICE_TOKEN_MODE unset) it emits the legacy
# `-H X-Service-Token: <token>`; in hmac mode it emits the signed
# `-H X-Service-Auth: v1.<ts>.<sig>`. SERVICE_TOKEN (or LIVE_SERVICE_TOKEN /
# INTERNAL_SERVICE_TOKEN) supplies the shared secret.

_svc_token() {
  printf '%s' "${SERVICE_TOKEN:-${LIVE_SERVICE_TOKEN:-${INTERNAL_SERVICE_TOKEN:-}}}"
}

# Resolve the active mode so scripts always match the LIVE deployment: explicit
# SERVICE_TOKEN_MODE wins; else read it off the running tenant-control container
# (docker-first gates); else static. Cached after first resolve.
_svc_mode() {
  if [ -n "${_SVC_MODE_CACHE:-}" ]; then printf '%s' "${_SVC_MODE_CACHE}"; return; fi
  local m="${SERVICE_TOKEN_MODE:-}"
  if [ -z "${m}" ]; then
    m=$(docker inspect mini-baas-tenant-control \
      --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | sed -n 's/^SERVICE_TOKEN_MODE=//p' | head -1)
  fi
  _SVC_MODE_CACHE="${m:-static}"
  printf '%s' "${_SVC_MODE_CACHE}"
}

# svc_compute_signature <token> <method> <path> <body> [ts]
svc_compute_signature() {
  local token="$1" method="$2" path="$3" body="${4:-}" ts="${5:-$(date +%s)}"
  local body_hex msg sig
  body_hex=$(printf '%s' "${body}" | openssl dgst -sha256 -hex | sed 's/^.*= //')
  msg=$(printf '%s\n%s\n%s\n%s' "${ts}" "${method}" "${path}" "${body_hex}")
  sig=$(printf '%s' "${msg}" | openssl dgst -sha256 -hmac "${token}" -hex | sed 's/^.*= //')
  printf 'v1.%s.%s' "${ts}" "${sig}"
}

# svc_auth <method> <backend_path> [body] — populates the global SVC_AUTH array
# with the curl `-H` flag(s) for the active mode (array, so the space in the
# header value never word-splits). BACKEND_PATH is the path the BACKEND service
# sees (the URL path only, no query) — for Kong routes with strip_path:true pass
# the post-strip upstream path (e.g. /databases/<id>, not /admin/v1/databases/<id>).
# Usage:
#   svc_auth POST /v1/tenants "$body"; curl ... "${SVC_AUTH[@]}" ... -d "$body"
SVC_AUTH=()
svc_auth() {
  local method="$1" path="$2" body="${3:-}" token
  token="$(_svc_token)"
  if [ "$(_svc_mode)" = "hmac" ]; then
    SVC_AUTH=(-H "X-Service-Auth: $(svc_compute_signature "${token}" "${method}" "${path}" "${body}")")
  else
    SVC_AUTH=(-H "X-Service-Token: ${token}")
  fi
}

# Self-test: `bash scripts/lib/service-auth.sh --selftest` proves the vector.
if [ "${1:-}" = "--selftest" ]; then
  got=$(svc_compute_signature "test-token" "POST" "/v1/keys/verify" '{"key":"abc"}' 1700000000)
  want="v1.1700000000.b2e684210cc7e80998388c89afe88d2fbd4fd9a7492289724f7fd3f15075189e"
  if [ "${got}" = "${want}" ]; then echo "service-auth.sh golden vector OK"; else
    echo "MISMATCH: got ${got} want ${want}" >&2; exit 1; fi
fi
