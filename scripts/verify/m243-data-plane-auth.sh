#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m243-data-plane-auth.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 13:05:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 13:05:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate (G1, ADR 0007/0009; D1, ADR 0023): the data plane's admin routes take
# signed service calls only, DDL needs a write-scoped app key, tenant code
# cannot reach the signing token, and each caller signs with its own key.
#
# Static (no stack): the admin routes sit in the router's service-auth group
# and not in the API-key bypass; the tests that prove each arm exist under
# names that carry the condition; the functions runtime spawns Workers with
# env off and gets no env_file; each DATA_PLANE_KEY_* reaches exactly its one
# holder plus the data plane; DATA_PLANE_CALLER_POLICY defaults to off; the
# generator mints both caller keys and never a _PREV.
#
# Live (M243_LIVE=1, scratch containers): the forged-identity arms under
# DATA_PLANE_CALLER_POLICY=enforce — m243-caller-policy-live.sh.
#
# What D1 proves: the caller CLASS (which key verified), the routes that class
# may reach, and that identity and mount name one tenant. What it does NOT
# prove: that the tenant the query-router asserts is the end user's — that
# stays trusted, as in ADR 0007. With the policy off (the default) the shared
# token is still accepted everywhere.
#
# Caveat: this proves the code and its tests exist, not that they pass;
# `cargo test --workspace` (Rust job), jest (Node job), `go test` and
# `deno test` (functions-runtime job) are the runtime proof. A renamed test
# fails here (noisy, safe); a test that exists but asserts nothing passes here
# (dangerous), which is why the names carry the condition. The holder check
# reads `  service:` lines and literal key names: a key passed by an anchor,
# `extends` or env_file is not seen (under-reports). The runtime process itself
# holds INTERNAL_SERVICE_TOKEN (it resolves secrets with it): a Worker sandbox
# escape would hold it too — this gate does not cover that.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUTES="${ROOT}/src/data-plane-router/crates/data-plane-server/src/routes"
QR="${ROOT}/src/apps/query-router/src/query"
FN="${ROOT}/infra/docker/services/functions-runtime/src"
STORAGE="${ROOT}/orchestrators/compose/base/storage.yml"
POOL="${ROOT}/src/data-plane-router/crates/data-plane-pool/src/service_auth"
TC="${ROOT}/src/control-plane"
COMPOSE="${ROOT}/orchestrators/compose/base"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}
step() { printf '\033[1m• %s\033[0m\n' "$*"; }
need() {
  grep -aEq -- "$2" "$1" || fail "$3 (expected /$2/ in ${1#"$ROOT"/})"
}
# The block between the `internal` router and its route_layer, i.e. the
# routes the service-auth layer guards.
internal_group() {
  sed -n '/let mut internal = Router::new()/,/inbound_auth::require_service_auth/p' "${ROUTES}/mod.rs"
}

step "static: every admin route is in the service-auth group, none in the bypass"
for route in /v1/admin/raw /v1/admin/migrate /v1/admin/rotate /v1/admin/evict-verify; do
  internal_group | grep -qF "\"${route}\"" || fail "${route} is outside the service-auth group"
done
! sed -n '/let bypass = /,/let mut internal/p' "${ROUTES}/mod.rs" | grep -q '/v1/admin' ||
  fail "an admin route is in the API-key bypass"
pass "4 admin routes behind require_service_auth"

step "static: the tests that prove each arm exist"
for pair in \
  "${ROUTES}/admin_auth_tests.rs|fn m243_unsigned_admin_routes_are_401" \
  "${ROUTES}/admin_auth_tests.rs|fn m243_a_plain_token_or_a_signature_for_another_body_is_401" \
  "${ROUTES}/admin_auth_tests.rs|fn m243_a_signed_admin_call_reaches_the_handler" \
  "${ROUTES}/admin_auth_tests.rs|fn m243_health_and_capabilities_stay_open" \
  "${ROUTES}/inbound_auth.rs|fn enforce_refuses_unsigned_and_wrong_body_and_serves_signed" \
  "${QR}/schema.service.spec.ts|a read-only key sending an unconfirmed drop gets 403, a writer gets 400" \
  "${QR}/schema.service.spec.ts|applies for an app key with %s scope" \
  "${QR}/schema.service.spec.ts|matches scopes exactly: apikey:admin is not admin" \
  "${FN}/worker-env.test.ts|the runtime's environment stays unreachable past the Deno.env replacement" \
  "${FN}/worker-env.test.ts|a secret never reaches the runtime's process environment"; do
  file="${pair%%|*}"
  need "${file}" "${pair#*|}" "missing test"
done
grep -q 'mod admin_auth_tests;' "${ROUTES}/mod.rs" || fail "admin_auth_tests.rs is not compiled"
pass "unsigned 401 · read-key DDL 403 · write-key DDL applies · Worker env sealed"

step "static: tenant code gets no env and no env_file"
[ "$(grep -ac 'env: workerEnv(secrets).permission\|env: env.permission' "${FN}/server.ts")" = 2 ] ||
  fail "a Worker is spawned without the sealed env permission"
need "${FN}/worker-env.ts" '^    permission: false,$' "the Worker env permission is not off"
! awk '/^  functions-runtime:/{p=1;next} p&&/^  [a-z_-]+:$/{p=0} p' "${STORAGE}" | grep -v '^ *#' | grep -q 'env_file' ||
  fail "functions-runtime gets an env_file"
pass "both Worker spawns sealed; storage.yml passes a fixed list"

step "static: the new file is under 300 lines with the 42 header"
f="${ROUTES}/admin_auth_tests.rs"
[ "$(wc -l <"${f}")" -le 300 ] || fail "admin_auth_tests.rs is over 300 lines"
need "${f}" 'By: dlesieur <dlesieur@student\.42\.fr>' "admin_auth_tests.rs has no 42 header"
pass "admin_auth_tests.rs"

step "static: the D1 tests that prove each caller-class arm exist"
for pair in \
  "${ROUTES}/caller_policy_tests.rs|fn k4_every_internal_route_has_exactly_one_policy_row" \
  "${ROUTES}/caller_policy_tests.rs|fn k4_each_route_admits_its_class_only" \
  "${ROUTES}/caller_policy_tests.rs|fn k6_query_router_on_an_admin_route_is_refused_whatever_roles_it_claims" \
  "${ROUTES}/caller_policy_tests.rs|fn k5_inline_dsn_is_admitted_only_where_the_table_says" \
  "${ROUTES}/caller_policy_tests.rs|fn k7_legacy_unsigned_and_unlisted_are_refused" \
  "${ROUTES}/caller_policy_tests.rs|fn k7_shadow_logs_would_deny_with_route_and_class_only_and_serves" \
  "${ROUTES}/caller_policy_tests.rs|fn k7_enforce_answers_403_and_off_never_judges" \
  "${ROUTES}/caller_policy_router_tests.rs|fn k4_every_route_answers_its_class_and_refuses_the_others" \
  "${ROUTES}/caller_policy_router_tests.rs|fn k9_the_prev_key_of_each_caller_still_verifies" \
  "${ROUTES}/caller_policy_router_tests.rs|fn k1_off_judges_no_class_and_caller_keys_only_add_to_g1a" \
  "${ROUTES}/caller_policy_router_tests.rs|fn k7_shadow_serves_what_enforce_refuses" \
  "${ROUTES}/caller_policy_router_tests.rs|fn k5_a_refused_inline_dsn_is_never_dialled" \
  "${ROUTES}/caller_policy_router_tests.rs|fn k5_an_allowed_class_does_dial_its_inline_dsn" \
  "${ROUTES}/caller_keys_tests.rs|fn k8_off_accepts_unset_keys_and_a_sound_set_starts" \
  "${ROUTES}/caller_keys_tests.rs|fn k8_off_still_refuses_a_short_or_padded_set_key" \
  "${ROUTES}/caller_keys_tests.rs|fn k8_a_padded_or_blank_key_refuses_and_names_only_the_variable" \
  "${ROUTES}/caller_keys_tests.rs|fn k8_unset_empty_or_short_keys_refuse_to_start" \
  "${ROUTES}/caller_keys_tests.rs|fn k8_a_key_equal_to_another_or_to_the_legacy_token_refuses_to_start" \
  "${ROUTES}/caller_keys_tests.rs|fn k8_the_refusal_names_the_variable_never_the_value" \
  "${POOL}/keyring.rs|fn the_key_that_verifies_is_the_one_reported" \
  "${POOL}/keyring.rs|fn an_empty_key_never_matches_even_signed_with_the_empty_key" \
  "${POOL}/keyring.rs|fn static_mode_compares_the_plain_token_against_every_key" \
  "${TC}/cmd/tenant-control/dataplane_key_test.go|func TestDataPlaneSigningKeyPrefersTheTenantControlKey" \
  "${TC}/internal/tenants/admin_relay_key_test.go|func TestAdminRelaySignsTheDataPlaneHopWithItsOwnKey" \
  "${ROOT}/src/apps/query-router/src/proxy/rust-data-plane.proxy.spec.ts|signs with DATA_PLANE_KEY_QUERY_ROUTER when set"; do
  need "${pair%%|*}" "${pair#*|}" "missing test"
done
for mod in caller_policy_tests caller_policy_router_tests caller_keys_tests; do
  grep -q "mod ${mod};" "${ROUTES}/mod.rs" || fail "${mod}.rs is not compiled"
done
pass "K1 · K4 · K5 · K6 · K7 · K8 · K9 named tests, compiled"

# Every `service|DATA_PLANE_KEY_*` pair the base compose files pass.
key_holders() {
  awk '/^services:/{s=1;next} /^[^ #]/{s=0} s&&/^  [a-z0-9_-]+:$/{svc=$1;sub(":","",svc)}
    s&&/^ +DATA_PLANE_KEY_[A-Z_]+:/{k=$1;sub(":","",k);print svc"|"k}' "${COMPOSE}"/*.yml | sort -u
}

step "static: each caller key reaches its one holder and the data plane (K11)"
want="data-plane-router-rust|DATA_PLANE_KEY_QUERY_ROUTER
data-plane-router-rust|DATA_PLANE_KEY_QUERY_ROUTER_PREV
data-plane-router-rust|DATA_PLANE_KEY_TENANT_CONTROL
data-plane-router-rust|DATA_PLANE_KEY_TENANT_CONTROL_PREV
query-router|DATA_PLANE_KEY_QUERY_ROUTER
tenant-control|DATA_PLANE_KEY_TENANT_CONTROL"
got="$(key_holders)"
[ "${got}" = "${want}" ] || fail "caller-key holders differ: $(printf '%s' "${got}" | tr '\n' ' ')"
! key_holders | grep -q '^functions-runtime|' || fail "functions-runtime holds a caller key"
need "${COMPOSE}/data-plane.yml" 'DATA_PLANE_CALLER_POLICY: \$\{DATA_PLANE_CALLER_POLICY:-off\}' \
  "the caller policy does not default to off"
# devil D1-P1: tenant-control reads the same value, or its relay and the data plane
# would judge one request under two policies.
for file in "${COMPOSE}/control-plane.yml" "${ROOT}/orchestrators/compose/docker-compose.monolith.yml"; do
  need "${file}" 'DATA_PLANE_CALLER_POLICY: \$\{DATA_PLANE_CALLER_POLICY:-off\}' \
    "tenant-control does not get the caller policy in ${file##*/}"
done
pass "query-router QR only · tenant-control TC only · functions-runtime none · policy off on both hops"

step "static: the generator mints both caller keys, never a _PREV (K9)"
gen="${ROOT}/scripts/env/generate-env.sh"
for key in DATA_PLANE_KEY_QUERY_ROUTER DATA_PLANE_KEY_TENANT_CONTROL; do
  need "${gen}" "^GENERATED_KEYS=\".* ${key}( |\")" "${key} is not a generated key"
  need "${gen}" "^${key}=\"\\\$\(openssl rand -hex 32\)\"$" "${key} is not minted"
done
! grep -q 'DATA_PLANE_KEY_[A-Z_]*_PREV' "${gen}" || fail "the generator writes a _PREV key"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
env_file="${scratch}/secrets"
bash "${gen}" "${env_file}" >/dev/null
grep -vE '^DATA_PLANE_KEY_' "${env_file}" >"${scratch}/old" && cp "${scratch}/old" "${env_file}"
before="$(sha256sum <"${scratch}/old")"
bash "${gen}" --topup "${env_file}" >/dev/null
[ "$(grep -cE '^DATA_PLANE_KEY_(QUERY_ROUTER|TENANT_CONTROL)=[0-9a-f]{64}$' "${env_file}")" = 2 ] ||
  fail "--topup did not add both caller keys"
[ "$(grep -vE '^DATA_PLANE_KEY_' "${env_file}" | sha256sum)" = "${before}" ] ||
  fail "--topup changed an existing value"
minted="$(sha256sum <"${env_file}")"
bash "${gen}" --topup "${env_file}" >/dev/null
[ "$(sha256sum <"${env_file}")" = "${minted}" ] || fail "a second --topup rotated a key"
pass "both minted with openssl rand -hex 32; --topup adds them and rotates nothing"

if [ "${M243_LIVE:-0}" = 1 ]; then
  bash "$(dirname "$0")/m243-caller-policy-live.sh"
else
  printf '  SKIP live forged-identity arms (set M243_LIVE=1; needs docker)\n'
fi

printf '\033[32mm243 checks passed\033[0m\n'
