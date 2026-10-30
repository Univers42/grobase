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
# Gate (G1, ADR 0007/0009): the data plane's admin routes take signed service
# calls only, DDL needs a write-scoped app key, and tenant code cannot reach
# the signing token.
#
# Static (no stack): the admin routes sit in the router's service-auth group
# and not in the API-key bypass; the tests that prove each arm exist under
# names that carry the condition; the functions runtime spawns Workers with
# env off and gets no env_file.
#
# Not covered yet: "forged body identity → 403" waits on the per-caller
# identity verdict (plan item "Identity comes from a verified claim").
#
# Caveat: this proves the code and its tests exist, not that they pass;
# `cargo test --workspace` (Rust job), jest (Node job) and `deno test`
# (functions-runtime job) are the runtime proof. A renamed test fails here
# (noisy, safe); a test that exists but asserts nothing passes here
# (dangerous), which is why the names carry the condition. The runtime process
# itself holds INTERNAL_SERVICE_TOKEN (it resolves secrets with it): a Worker
# sandbox escape would hold it too — this gate does not cover that.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUTES="${ROOT}/src/data-plane-router/crates/data-plane-server/src/routes"
QR="${ROOT}/src/apps/query-router/src/query"
FN="${ROOT}/infra/docker/services/functions-runtime/src"
STORAGE="${ROOT}/orchestrators/compose/base/storage.yml"

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

printf '\033[32mm243 static checks passed\033[0m (forged-identity arm pending)\n'
