#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    lib-mount-admin.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/29 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/29 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Tenant mount administration through the REAL gateway, for seeders: resolve
# the app key's tenant + owner principal, register / look up / deregister a
# mount (adapter-registry behind Kong /admin/v1/databases), and call the data
# plane with the app's own key (/query/v1). The same steps live inline in
# seed-live-demo.sh and osionos-extra-engines.sh; this is their shared form.
# Secrets never reach argv: request bodies go to curl on stdin, and nothing
# here prints a key, token or DSN.
#
# Needs lib-live-tenant.sh (_lt_env, _lt_host_port, _lt_json_field, which
# sources service-auth.sh) and MA_TMP set to a private scratch directory.
#
# Caveat: ma_register reads 409 as "already registered" and returns the
# existing id WITHOUT updating its DSN — a rotated credential needs
# ma_deregister first. ma_router_engines trusts the router's own
# /v1/capabilities list; an unreachable router reads as "no engines".

# ma_resolve_app APP_ENV_FILE — sets MA_KONG_URL MA_ANON_KEY MA_SERVICE_KEY
# MA_APP_KEY MA_TENANT MA_KEY_ID MA_OWNER (api-key:<key uuid>) and exports
# SERVICE_TOKEN for svc_auth. Returns 1 with a reason on stderr.
ma_resolve_app() {
  local kong_port tc_port vbody verify
  kong_port="$(_lt_host_port mini-baas-kong 8000/tcp)"
  tc_port="$(_lt_host_port mini-baas-tenant-control 3022/tcp)"
  if [[ -z "${kong_port}" || -z "${tc_port}" ]]; then
    echo "stack not up (kong/tenant-control host ports unmapped)" >&2
    return 1
  fi
  MA_KONG_URL="http://127.0.0.1:${kong_port}"
  SERVICE_TOKEN="$(_lt_env mini-baas-tenant-control INTERNAL_SERVICE_TOKEN)"
  export SERVICE_TOKEN
  MA_ANON_KEY="$(_lt_env mini-baas-kong KONG_PUBLIC_API_KEY)"
  MA_SERVICE_KEY="$(_lt_env mini-baas-kong KONG_SERVICE_API_KEY)"
  if [[ -z "${SERVICE_TOKEN}" || -z "${MA_ANON_KEY}" || -z "${MA_SERVICE_KEY}" ]]; then
    echo "control-plane credentials unset on the running containers (INTERNAL_SERVICE_TOKEN / KONG_PUBLIC_API_KEY / KONG_SERVICE_API_KEY)" >&2
    return 1
  fi
  MA_APP_KEY="${BAAS_API_KEY:-$(sed -n 's/^VITE_BAAS_API_KEY=//p' "$1" 2>/dev/null | head -1)}"
  if [[ "${MA_APP_KEY}" != mbk_* ]]; then
    echo "no tenant API key: BAAS_API_KEY unset and no VITE_BAAS_API_KEY in $1" >&2
    return 1
  fi
  vbody="{\"key\":\"${MA_APP_KEY}\"}"
  svc_auth POST /v1/keys/verify "${vbody}"
  verify="$(printf '%s' "${vbody}" | curl -fsS -X POST "http://127.0.0.1:${tc_port}/v1/keys/verify" \
    "${SVC_AUTH[@]}" -H 'Content-Type: application/json' --data-binary @-)" || {
    echo "tenant-control /v1/keys/verify unreachable" >&2
    return 1
  }
  grep -q '"valid":true' <<<"${verify}" || {
    echo "the app key is not valid" >&2
    return 1
  }
  MA_TENANT="$(_lt_json_field tenant_id <<<"${verify}")"
  MA_KEY_ID="$(_lt_json_field key_id <<<"${verify}")"
  [[ -n "${MA_TENANT}" && -n "${MA_KEY_ID}" ]] || {
    echo "verify response missing tenant_id/key_id" >&2
    return 1
  }
  MA_OWNER="api-key:${MA_KEY_ID}"
}

# ma_admin METHOD PATH [BODY] — service-key admin call; echoes the HTTP code,
# body in ${MA_TMP}/admin.json. DELETE is HMAC-signed on the post-strip path.
ma_admin() {
  local extra=()
  if [[ "$1" == "DELETE" ]]; then
    svc_auth DELETE "${2#/admin/v1}" ""
    extra=("${SVC_AUTH[@]}")
  fi
  [[ -z "${3:-}" ]] || extra+=(-H 'Content-Type: application/json' --data-binary @-)
  printf '%s' "${3:-}" | curl -s -o "${MA_TMP}/admin.json" -w '%{http_code}' -X "$1" \
    "${MA_KONG_URL}$2" -H "apikey: ${MA_SERVICE_KEY}" -H "X-Tenant-Id: ${MA_TENANT}" "${extra[@]}"
}

# ma_mount_id NAME — the tenant mount id for NAME, or empty.
ma_mount_id() {
  [[ "$(ma_admin GET /admin/v1/databases)" == "200" ]] || return 0
  MNT="$1" python3 -c 'import json,os,sys
rows = json.load(open(sys.argv[1]))
print(next((r["id"] for r in rows if r.get("name") == os.environ["MNT"]), ""))' "${MA_TMP}/admin.json"
}

# ma_register ENGINE NAME DSN — sets MA_REG_CODE and MA_REG_ID (201 created,
# 409 reused by name). The DSN travels in env + stdin, never argv.
ma_register() {
  local body
  body="$(MA_E="$1" MA_N="$2" MA_D="$3" python3 -c 'import json,os
print(json.dumps({"engine": os.environ["MA_E"], "name": os.environ["MA_N"], "connection_string": os.environ["MA_D"]}))')"
  MA_REG_ID=""
  MA_REG_CODE="$(ma_admin POST /admin/v1/databases "${body}")"
  case "${MA_REG_CODE}" in
  201) MA_REG_ID="$(_lt_json_field id <"${MA_TMP}/admin.json")" ;;
  409) MA_REG_ID="$(ma_mount_id "$2")" ;;
  esac
  [[ -n "${MA_REG_ID}" ]]
}

# ma_deregister ID — remove a mount by id; 200/204/404 all count as gone.
ma_deregister() {
  [[ "$(ma_admin DELETE "/admin/v1/databases/$1")" =~ ^(200|204|404)$ ]]
}

# ma_gw METHOD PATH [BODY] — data-plane call with the app's key; echoes the
# HTTP code, body in ${MA_TMP}/gw.json. A 429 waits for RateLimit-Reset; a
# 502/503 retries up to 5 times, 3 s apart.
ma_gw() {
  local code reset tries=0 body=()
  [[ -z "${3:-}" ]] || body=(-H 'Content-Type: application/json' --data-binary @-)
  while :; do
    code="$(printf '%s' "${3:-}" | curl -s -o "${MA_TMP}/gw.json" -D "${MA_TMP}/gw.hdr" -w '%{http_code}' \
      -X "$1" "${MA_KONG_URL}$2" -H "apikey: ${MA_ANON_KEY}" -H "X-Baas-Api-Key: ${MA_APP_KEY}" "${body[@]}")"
    if [[ "${code}" == "429" ]]; then
      reset="$(sed -n 's/^[Rr]ate[Ll]imit-[Rr]eset:[[:space:]]*\([0-9]*\).*/\1/p' "${MA_TMP}/gw.hdr" | head -1)"
      sleep "${reset:-5}"
      continue
    fi
    if [[ "${code}" =~ ^(502|503)$ ]] && ((tries < 5)); then
      tries=$((tries + 1))
      sleep 3
      continue
    fi
    printf '%s' "${code}"
    return 0
  done
}

# ma_router_engines — the engines the RUNNING router image was compiled with.
ma_router_engines() {
  local port
  port="$(_lt_host_port mini-baas-data-plane-router-rust 4011/tcp)"
  [[ -n "${port}" ]] || return 0
  curl -s "http://127.0.0.1:${port}/v1/capabilities" 2>/dev/null | python3 -c 'import json,sys
try: print(" ".join(e.get("engine", "") for e in json.load(sys.stdin).get("engines", [])))
except Exception: print("")'
}

# ma_ready CONTAINER — running, not restarting, healthy (or no healthcheck).
ma_ready() {
  [[ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}} {{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "$1" 2>/dev/null)" == "true false healthy" ]]
}
