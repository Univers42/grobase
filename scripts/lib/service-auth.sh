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
#   svc_auth POST /v1/keys/verify '{"key":"x"}'        # fills the SVC_AUTH array
#   curl ... "${SVC_AUTH[@]}" -d '{"key":"x"}' ...
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
  if [ -n "${_SVC_MODE_CACHE:-}" ]; then
    printf '%s' "${_SVC_MODE_CACHE}"
    return
  fi
  local m="${SERVICE_TOKEN_MODE:-}"
  if [ -z "${m}" ]; then
    m=$(docker inspect mini-baas-tenant-control \
      --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
      sed -n 's/^SERVICE_TOKEN_MODE=//p' | head -1)
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
  svc_auth_with "$(_svc_token)" "$@"
}

# svc_auth_with <token> <method> <path> [body] — svc_auth with an explicit token.
# SVC_AUTH_TS pins the signature timestamp (the self-test uses it).
svc_auth_with() {
  local token="$1" method="$2" path="$3" body="${4:-}" sig
  if [ "$(_svc_mode)" = "hmac" ]; then
    sig="$(svc_compute_signature "${token}" "${method}" "${path}" "${body}" "${SVC_AUTH_TS:-}")"
    SVC_AUTH=(-H "X-Service-Auth: ${sig}")
  else
    SVC_AUTH=(-H "X-Service-Token: ${token}")
  fi
}

# D1 (ADR 0023): the data plane tells callers apart by the key that verifies,
# so a script calling it signs as the class that owns the route: query_router
# (/v1/query, schema, transactions, probe, permissions) or tenant_control
# (/v1/admin/*). The key comes from the environment, else from the running
# holder container (as _svc_mode does), else the shared token, which the data
# plane accepts only while DATA_PLANE_CALLER_POLICY is off.
svc_class_key() { # $1 = query_router | tenant_control
  local var holder key
  case "$1" in
  query_router) var=DATA_PLANE_KEY_QUERY_ROUTER holder=mini-baas-query-router ;;
  tenant_control) var=DATA_PLANE_KEY_TENANT_CONTROL holder=mini-baas-tenant-control ;;
  *)
    printf 'svc_class_key: unknown caller class %s\n' "$1" >&2
    return 2
    ;;
  esac
  key="${!var:-}"
  [ -n "${key}" ] || key=$(docker inspect "${holder}" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    sed -n "s/^${var}=//p" | head -1)
  printf '%s' "${key:-$(_svc_token)}"
}

# svc_auth_as <class> <method> <path> [body] — svc_auth, signed with the class key.
svc_auth_as() {
  local token
  token="$(svc_class_key "$1")" || return
  shift
  svc_auth_with "${token}" "$@"
}

# svc_curl_as <class> <curl args...> — curl with the class's auth header added.
# The signed path is the URL path, the body the -d argument, the method -X
# (else POST with a body, GET without).
# Caveat: reads only `-d`/`--data`/`--data-raw`/`--data-binary <value>` and
# `-X <method>` as separate words, and the first http(s):// word as the URL. A
# body from `-d @file` or `--data=...` is signed as its literal text, so the
# receiver answers 401; pass the body as its own word.
svc_curl_as() {
  local class="$1" url="" body="" method="" prev="" arg path
  shift
  for arg in "$@"; do
    case "${prev}" in
    -d | --data | --data-raw | --data-binary) body="${arg}" ;;
    -X) method="${arg}" ;;
    esac
    case "${arg}" in http://* | https://*) [ -n "${url}" ] || url="${arg}" ;; esac
    prev="${arg}"
  done
  [ -n "${method}" ] || { [ -n "${body}" ] && method=POST || method=GET; }
  path="/${url#*://*/}"
  svc_auth_as "${class}" "${method}" "${path%%\?*}" "${body}" || return
  curl "$@" "${SVC_AUTH[@]}"
}

# svc_scratch_caller_keys — throwaway per-caller keys for a scratch data plane.
# Exports both DATA_PLANE_KEY_* and DATA_PLANE_CALLER_POLICY (default off) and
# fills SVC_CALLER_ENV with their docker `-e NAME` flags: names only, so no key
# reaches a process argv.
SVC_CALLER_ENV=()
svc_scratch_caller_keys() {
  export DATA_PLANE_CALLER_POLICY="${DATA_PLANE_CALLER_POLICY:-off}"
  DATA_PLANE_KEY_QUERY_ROUTER="$(openssl rand -hex 32)"
  DATA_PLANE_KEY_TENANT_CONTROL="$(openssl rand -hex 32)"
  export DATA_PLANE_KEY_QUERY_ROUTER DATA_PLANE_KEY_TENANT_CONTROL
  SVC_CALLER_ENV=(-e DATA_PLANE_CALLER_POLICY -e DATA_PLANE_KEY_QUERY_ROUTER
    -e DATA_PLANE_KEY_TENANT_CONTROL)
}

# Self-test: `bash scripts/lib/service-auth.sh --selftest` proves the vector.
if [ "${1:-}" = "--selftest" ]; then
  got=$(svc_compute_signature "test-token" "POST" "/v1/keys/verify" '{"key":"abc"}' 1700000000)
  want="v1.1700000000.b2e684210cc7e80998388c89afe88d2fbd4fd9a7492289724f7fd3f15075189e"
  if [ "${got}" = "${want}" ]; then echo "service-auth.sh golden vector OK"; else
    echo "MISMATCH: got ${got} want ${want}" >&2
    exit 1
  fi
  # svc_curl_as signs the URL path and the -d body with the class key, not the
  # shared token; curl is stubbed to print the header it would send.
  curl() { printf '%s\n' "${@: -1}"; }
  SERVICE_TOKEN_MODE=hmac SVC_AUTH_TS=1700000000 SERVICE_TOKEN=shared-token \
    DATA_PLANE_KEY_TENANT_CONTROL=test-token
  got=$(svc_curl_as tenant_control -s -X POST "http://dp:4011/v1/keys/verify?x=1" -d '{"key":"abc"}')
  if [ "${got}" = "X-Service-Auth: ${want}" ]; then echo "svc_curl_as class signature OK"; else
    echo "MISMATCH: svc_curl_as got ${got}" >&2
    exit 1
  fi
  unset -f curl
fi
