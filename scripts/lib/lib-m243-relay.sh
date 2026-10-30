# shellcheck shell=bash
# lib-m243-relay.sh — the tenant-control admin-relay legs of m243's live gate (D1,
# ADR 0023): the Kong apikey arm, and the service-token arm under each caller policy
# (devil D1-P1). Sourced by m243-caller-policy-live.sh after its helpers (envelope,
# mount_json, migrate_tail, has_table, boot_tenant_control, tc_start, pass, fail,
# BODY, TC_PORT, TCC, LEGACY, KONG_SERVICE_API_KEY).

# relay_body <table> — a migrate whose body claims a forged identity (tenant t2, no roles).
relay_body() {
  local forged
  forged="$(envelope t2 "$(mount_json relay-"$1" t1 postgres)" "$(migrate_tail "$1")")"
  printf '%s' "${forged/\"roles\":\[\"service_role\"\]/\"roles\":[]}"
}

# relay_with <table> <header args...> — status of tenant-control's admin relay of relay_body.
relay_with() {
  local payload
  payload="$(relay_body "$1")"
  shift
  curl -s -o "${BODY}" -w '%{http_code}' -X POST "http://127.0.0.1:${TC_PORT}/v1/admin/migrate" \
    -H 'Content-Type: application/json' "$@" -d "${payload}"
}

relay() { relay_with "$2" -H "apikey: $1"; }

# relay_token <table> — the relay, HMAC-signed with the shared service token.
relay_token() {
  svc_auth_with "${LEGACY}" POST /v1/admin/migrate "$(relay_body "$1")"
  relay_with "$1" "${SVC_AUTH[@]}"
}

relay_arms() {
  local got
  got="$(relay "$(openssl rand -hex 32)" m243_relay_bad)"
  [ "${got}" = 401 ] || fail "relay with a wrong apikey: want 401, got ${got}"
  pass "relay with a wrong apikey → 401"
  got="$(relay "${KONG_SERVICE_API_KEY}" m243_relay)"
  [ "${got}" = 200 ] || fail "relay migrate: want 200, got ${got} — $(head -c 200 "${BODY}")"
  has_table m243_relay || fail "the relayed migrate created no table"
  pass "Kong relay (tenant-control apikey arm, signed with its own key) → 200"
}
