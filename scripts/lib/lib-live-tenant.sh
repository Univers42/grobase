#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    lib-live-tenant.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Reusable live-stack helper for verify gates: provision a scratch
# (tenant, API key, postgresql mount) triple against the RUNNING mini-baas
# stack so a gate can exercise the REAL gateway path — Kong key-auth →
# query-router ApiKeyMiddleware (tenant-control /v1/keys/verify) →
# adapter-registry mount resolution → Rust data plane.
#
# Everything is discovered from the running containers (docker inspect /
# docker port), never from the caller's shell, so a wrong host env can't
# poison the probe:
#   - tenant-control service token : container env INTERNAL_SERVICE_TOKEN
#   - Kong consumer keys           : container env KONG_PUBLIC/SERVICE_API_KEY
#   - host ports                   : docker port (resolve-ports.sh may have
#                                    moved them off the defaults)
#   - scratch mount DSN            : postgres container env, host `postgres`
#                                    (the in-network alias the data plane dials)
#
# Usage (source, then):
#   live_tenant_provision <slug>     # idempotent; sets the LIVE_TENANT_* vars
#   live_tenant_cleanup              # best-effort revoke/deregister (EXIT trap)
#
# Exported on success:
#   LIVE_TENANT_SLUG      tenant id (slug) — adapter-registry rows key on it
#   LIVE_TENANT_KEY_ID    minted key uuid (the api-key actor is api-key:<this>)
#   LIVE_TENANT_API_KEY   full mbk_… key (send as X-Baas-Api-Key)
#   LIVE_TENANT_DB_ID     registered mount id (the /query/v1/<dbId> path part)
#   LIVE_KONG_URL         http://127.0.0.1:<resolved kong host port>
#   LIVE_ANON_APIKEY      Kong anon consumer key (send as apikey)
#   LIVE_SERVICE_APIKEY   Kong service_role consumer key (admin routes)
#   LIVE_SERVICE_TOKEN    control-plane service token (X-Service-Token)
#   LIVE_TENANT_CONTROL_URL  http://127.0.0.1:<resolved tenant-control port>

# v1 HMAC service auth (audit O1): when SERVICE_TOKEN_MODE=hmac the direct
# tenant-control / adapter-registry calls below sign per-request instead of
# sending the raw token. Sourced relative to this lib.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/service-auth.sh"

# Container env var (works for distroless images — no `sh` needed).
_lt_env() { # $1 container, $2 var
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep "^$2=" | head -1 | cut -d= -f2-
}

# Host port a container publishes for $2 (e.g. 8000/tcp) — empty if unmapped.
_lt_host_port() { # $1 container, $2 container-port/proto
  docker port "$1" "$2" 2>/dev/null | head -1 | sed 's/.*://'
}

# First "field":"value" occurrence in a JSON blob (control-plane responses are
# flat enough that this stays unambiguous; values are uuid/slug/key-safe).
_lt_json_field() { # $1 field, stdin json
  sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1
}

live_tenant_provision() { # $1 slug (must match ^[a-z0-9][a-z0-9_-]{1,62}$)
  local slug="$1"
  [[ -n "${slug}" ]] || { echo "live_tenant_provision: slug required" >&2; return 1; }

  local kong_port tc_port
  kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
  tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
  [[ -n "${kong_port}" ]] || { echo "kong host port not found (is the stack up?)" >&2; return 1; }
  [[ -n "${tc_port}" ]] || { echo "tenant-control host port not found" >&2; return 1; }
  LIVE_KONG_URL="http://127.0.0.1:${kong_port}"
  LIVE_TENANT_CONTROL_URL="http://127.0.0.1:${tc_port}"

  LIVE_SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
  LIVE_ANON_APIKEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
  LIVE_SERVICE_APIKEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
  [[ -n "${LIVE_SERVICE_TOKEN}" ]] || { echo "INTERNAL_SERVICE_TOKEN not found on tenant-control" >&2; return 1; }
  [[ -n "${LIVE_ANON_APIKEY}" && -n "${LIVE_SERVICE_APIKEY}" ]] \
    || { echo "Kong consumer keys not found on mini-baas-kong" >&2; return 1; }

  # 1) tenant — idempotent: 201 created or 409 already exists are both fine.
  local code tbody
  tbody="{\"id\":\"${slug}\",\"name\":\"${slug}\"}"
  svc_auth POST /v1/tenants "${tbody}"
  code=$(curl -s -o /tmp/lt-tenant.json -w '%{http_code}' -X POST \
    "${LIVE_TENANT_CONTROL_URL}/v1/tenants" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
    -d "${tbody}")
  [[ "${code}" == "201" || "${code}" == "409" ]] \
    || { echo "tenant create failed (${code}): $(cat /tmp/lt-tenant.json)" >&2; return 1; }
  LIVE_TENANT_SLUG="${slug}"

  # 1b) Put the probe on the `enterprise` (→ max) tier so gates can register any
  # engine + use any op under PACKAGE_ENFORCEMENT=1 (the live config). The gates
  # test functionality/parity, not tiering — m28 covers tiering on its own
  # tenants. Best-effort: a non-200 (older tenant-control without PATCH) leaves
  # the default tier, which is fine for pg-only gates.
  local pbody='{"plan":"enterprise"}'
  svc_auth PATCH "/v1/tenants/${slug}" "${pbody}"
  curl -s -o /dev/null -X PATCH "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${slug}" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "${pbody}" || true

  # 2) API key — read+write scopes (what an app key carries; admin not needed).
  local kbody='{"name":"verify-probe","scopes":["read","write"]}'
  svc_auth POST "/v1/tenants/${slug}/keys" "${kbody}"
  code=$(curl -s -o /tmp/lt-key.json -w '%{http_code}' -X POST \
    "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${slug}/keys" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' \
    -d "${kbody}")
  [[ "${code}" == "201" ]] || { echo "key mint failed (${code}): $(cat /tmp/lt-key.json)" >&2; return 1; }
  LIVE_TENANT_API_KEY="$(_lt_json_field key < /tmp/lt-key.json)"
  LIVE_TENANT_KEY_ID="$(_lt_json_field id < /tmp/lt-key.json)"
  [[ "${LIVE_TENANT_API_KEY}" == mbk_* ]] || { echo "minted key has unexpected shape" >&2; return 1; }

  # 3) scratch postgresql mount THROUGH THE GATEWAY (the adapter-registry
  #    /admin/v1/databases route): identity = X-Tenant-Id (the slug), guarded
  #    by Kong key-auth + ip-restriction. DSN points at the stack's own
  #    postgres (in-network alias), credentials read from the live container.
  local pg_user pg_pass pg_db unique_name
  pg_user="$(_lt_env mini-baas-postgres POSTGRES_USER)"; pg_user="${pg_user:-postgres}"
  pg_pass="$(_lt_env mini-baas-postgres POSTGRES_PASSWORD)"; pg_pass="${pg_pass:-postgres}"
  pg_db="$(_lt_env mini-baas-postgres POSTGRES_DB)"; pg_db="${pg_db:-postgres}"
  unique_name="probe-$(date +%s)"
  code=$(curl -s -o /tmp/lt-mount.json -w '%{http_code}' -X POST \
    "${LIVE_KONG_URL}/admin/v1/databases" \
    -H "apikey: ${LIVE_SERVICE_APIKEY}" -H "X-Tenant-Id: ${slug}" \
    -H 'Content-Type: application/json' \
    -d "{\"engine\":\"postgresql\",\"name\":\"${unique_name}\",\"connection_string\":\"postgres://${pg_user}:${pg_pass}@postgres:5432/${pg_db}\"}")
  [[ "${code}" == "201" ]] || { echo "mount register failed (${code}): $(cat /tmp/lt-mount.json)" >&2; return 1; }
  LIVE_TENANT_DB_ID="$(_lt_json_field id < /tmp/lt-mount.json)"
  [[ -n "${LIVE_TENANT_DB_ID}" ]] || { echo "mount register returned no id" >&2; return 1; }

  export LIVE_TENANT_SLUG LIVE_TENANT_KEY_ID LIVE_TENANT_API_KEY LIVE_TENANT_DB_ID
  export LIVE_KONG_URL LIVE_ANON_APIKEY LIVE_SERVICE_APIKEY LIVE_SERVICE_TOKEN
  export LIVE_TENANT_CONTROL_URL
  return 0
}

# Best-effort teardown (safe to call from an EXIT trap, never fails the gate):
# deregister the mount, revoke the key, soft-delete the tenant.
live_tenant_cleanup() {
  # Kong /admin/v1/databases has strip_path:true → adapter-registry sees the
  # bare /databases/<id>; that is the path the HMAC signature must bind.
  if [[ -n "${LIVE_TENANT_DB_ID:-}" ]]; then
    svc_auth DELETE "/databases/${LIVE_TENANT_DB_ID}" ""
    curl -s -o /dev/null -X DELETE \
      "${LIVE_KONG_URL}/admin/v1/databases/${LIVE_TENANT_DB_ID}" \
      -H "apikey: ${LIVE_SERVICE_APIKEY}" "${SVC_AUTH[@]}" \
      -H "X-Tenant-Id: ${LIVE_TENANT_SLUG}" || true
  fi
  if [[ -n "${LIVE_TENANT_KEY_ID:-}" ]]; then
    svc_auth DELETE "/v1/tenants/${LIVE_TENANT_SLUG}/keys/${LIVE_TENANT_KEY_ID}" ""
    curl -s -o /dev/null -X DELETE \
      "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${LIVE_TENANT_SLUG}/keys/${LIVE_TENANT_KEY_ID}" \
      "${SVC_AUTH[@]}" || true
  fi
  if [[ -n "${LIVE_TENANT_SLUG:-}" ]]; then
    svc_auth DELETE "/v1/tenants/${LIVE_TENANT_SLUG}" ""
    curl -s -o /dev/null -X DELETE \
      "${LIVE_TENANT_CONTROL_URL}/v1/tenants/${LIVE_TENANT_SLUG}" \
      "${SVC_AUTH[@]}" || true
  fi
  return 0
}
