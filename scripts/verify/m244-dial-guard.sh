#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m244-dial-guard.sh                                 :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 10:57:31 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 10:57:31 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate (G2 slices D1/D2/D3a/D4, ADR 0019): the data plane dials a tenant's
# pgwire, MySQL, SQL Server, Redis or DynamoDB host only after one classifier has vetted it, behind
# DATA_PLANE_DIAL_GUARD=off|shadow|enforce (off by default, a typo refuses
# startup).
#
# Static (no stack): one classifier that http calls too, the startup refusal,
# provenance set only by the static DATA_PLANE_MOUNTS step, the driver hooks
# that pin each dial, the tests that prove C1–C9, the Caveats, no subnet
# allowlist (C13), and the 300-line cap and 42 header on every new file.
#
# Caveat: this proves the code and its tests exist, not that they pass;
# `cargo test --workspace` in the Rust CI job is the runtime proof. A renamed
# test fails here (noisy, safe); a test that exists but asserts nothing
# passes here (dangerous), which is why the names carry the condition.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CRATES="${ROOT}/src/data-plane-router/crates"
POOL="${CRATES}/data-plane-pool/src"
SERVER="${CRATES}/data-plane-server/src"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗ %s\033[0m\n' "$*" >&2
  exit 1
}
step() { printf '\033[1m• %s\033[0m\n' "$*"; }
need() {
  grep -Eq -- "$2" "$1" || fail "$3 (expected /$2/ in ${1#"$ROOT"/})"
}

NEW_FILES="dial_guard/mod.rs dial_guard/classify.rs dial_guard/classify_tests.rs
dial_guard/scope.rs postgres/dial.rs postgres/dial_tests.rs mysql/dial.rs mysql/dial_tests.rs
redis/dial.rs redis/dial_tests.rs mssql/dial.rs mssql/dial_tests.rs
dynamodb_dial.rs dynamodb_dial_tests.rs"

step "static: the guard's files exist, under 300 lines, with the 42 header"
for f in ${NEW_FILES}; do
  [ -f "${POOL}/${f}" ] || fail "missing ${f}"
  [ "$(wc -l <"${POOL}/${f}")" -le 300 ] || fail "${f} is over 300 lines"
  need "${POOL}/${f}" 'By: dlesieur <dlesieur@student\.42\.fr>' "${f} has no 42 header"
done
pass "14 files"

step "static: one classifier (http calls it, its own copy is gone)"
need "${POOL}/http/validate.rs" 'use crate::dial_guard::classify::\{classify, denied_name\}' "http does not call the shared classifier"
! grep -q 'fn is_blocked_ip' "${POOL}/http/validate.rs" || fail "http/validate.rs still owns a classifier"
[ "$(grep -rl 'is_private()' "${POOL}" | grep -cv 'dial_guard/classify')" = 0 ] ||
  fail "an address range is classified outside dial_guard/classify.rs"
need "${POOL}/dial_guard/classify.rs" 'nat64' "NAT64 64:ff9b::/96 is not decoded (C6)"
need "${POOL}/dial_guard/classify.rs" '0x2002' "6to4 2002::/16 is not decoded (C6)"
for ip in '"224.0.0.1"' '"240.0.0.1"' '"198.18.0.1"' '"::127.0.0.1"' '"64:ff9b::a9fe:a9fe"' '"2002:7f00:1::"'; do
  grep -qF -- "${ip}" "${POOL}/dial_guard/classify_tests.rs" || fail "the classifier table no longer covers ${ip}"
done
pass "http/validate.rs → dial_guard::classify; gaps and embeddings in the table"

step "static: the mode flag defaults off and a typo refuses startup (C8)"
need "${POOL}/dial_guard/mod.rs" 'DIAL_GUARD_KEY: &str = "DATA_PLANE_DIAL_GUARD"' "the env key moved"
need "${POOL}/dial_guard/mod.rs" '#\[default\]' "the mode has no default"
need "${SERVER}/environment.rs" 'UnknownDialGuardMode' "no startup refusal for an unknown mode"
need "${SERVER}/config.rs" 'return Err\(ConfigError::UnknownDialGuardMode\)' "try_from_env does not refuse a typo"
[ "$(grep -c '\.with_dial_guard(dial_guard)' "${SERVER}/routes/state_build.rs")" = 7 ] ||
  fail "postgres, cockroach, mysql, mariadb, redis, dynamodb and mssql must all take the mode"
pass "DATA_PLANE_DIAL_GUARD wired to the seven adapters"

step "static: provenance comes from resolve, Platform only from DATA_PLANE_MOUNTS (C5)"
[ "$(sed '/^mod tests/,$d' "${POOL}/resolver.rs" | grep -c 'provenance: Provenance::Platform')" = 1 ] ||
  fail "Platform must be produced by exactly one resolver step"
need "${POOL}/dial_guard/scope.rs" 'Provenance::Platform' "the scope does not skip Platform"
pass "one Platform step"

step "static: the driver hooks pin every dial (C1 C2 C4 C9)"
need "${POOL}/postgres/dial.rs" 'Manager::from_connect' "pgwire does not vet at each physical dial"
need "${POOL}/postgres/dial.rs" 'get_hostaddrs\(\)' "tenant hostaddrs are not classified"
need "${POOL}/postgres/adapter.rs" 'dial::build_pool' "the pg adapter bypasses the guard"
need "${POOL}/mysql/dial.rs" 'resolved_ips\(Some' "mysql is not pinned to the vetted IPs"
need "${POOL}/mysql/dial.rs" 'prefer_socket\(false\)' "mysql may hop to a unix socket"
need "${POOL}/mysql/dial.rs" 'opts\.socket\(\)' "a mysql socket= is not refused"
need "${POOL}/mysql/adapter.rs" 'DialPool::open' "the mysql adapter bypasses the guard"
need "${POOL}/redis/dial.rs" 'IntoConnectionInfo' "redis does not parse the driver's connection info"
need "${POOL}/redis/dial.rs" 'ConnectionAddr::Tcp' "redis does not pin a TCP address"
need "${POOL}/redis/dial.rs" 'ConnectionAddr::Unix' "redis does not refuse a unix socket (C11)"
need "${POOL}/redis/adapter.rs" 'DialManager' "the redis adapter bypasses the guard"
need "${POOL}/mssql/dial.rs" 'impl bb8::ManageConnection for DialManager' "mssql still dials through bb8-tiberius"
need "${POOL}/mssql/dial.rs" 'Error::Routing' "a TDS Routing redirect is not vetted (C10)"
need "${POOL}/mssql/dial.rs" 'DenyClass::NamedInstance' "a named instance is not refused (C10)"
need "${POOL}/mssql/adapter.rs" 'DialManager' "the mssql adapter bypasses the guard"
need "${POOL}/dynamodb_dial.rs" 'impl ResolveDns for VettingResolver' "dynamodb lookups are not vetted per connection (C12)"
need "${POOL}/dynamodb_dial.rs" 'build_with_resolver' "the dynamodb connector does not use the vetting resolver"
need "${POOL}/dynamodb_dial.rs" 'DenyClass::DefaultCredentials' "a keyless dynamodb Tenant is not refused (C12)"
need "${POOL}/dynamodb.rs" 'loader\.http_client\(guard\.http_client\(\)\)' "the dynamodb adapter bypasses the guard"
pass "deadpool Connect + mysql resolved_ips + redis pinned address + mssql own manager + dynamodb resolver"

step "static: the tests that prove each condition exist"
for pair in \
  "dial_guard/classify_tests.rs|fn classifier_table_covers_every_range" \
  "dial_guard/classify_tests.rs|fn nothing_the_pre_g2_classifier_refused_is_now_allowed" \
  "dial_guard/classify_tests.rs|fn every_embedding_is_judged_by_its_ipv4" \
  "dial_guard/mod.rs|fn mode_parses_the_three_values_and_refuses_the_rest" \
  "dial_guard/scope.rs|fn line_escapes_and_caps_caller_fields" \
  "resolver.rs|fn provenance_is_platform_only_for_the_static_map" \
  "resolver.rs|fn a_provenance_key_in_the_body_has_no_effect" \
  "postgres/dial_tests.rs|fn pg_enforce_denies_loopback_metadata_and_names_resolving_to_them" \
  "postgres/dial_tests.rs|fn pg_every_host_and_tenant_hostaddr_is_classified" \
  "postgres/dial_tests.rs|fn pg_repointed_dsn_with_tenant_hostaddr_is_denied" \
  "postgres/dial_tests.rs|fn pg_each_dial_resolves_again_and_uses_the_new_vetted_ip" \
  "postgres/dial_tests.rs|fn pg_shadow_logs_would_deny_and_dials_unchanged" \
  "postgres/dial_tests.rs|fn pg_adapter_refuses_tenant_dsns_and_passes_platform" \
  "mysql/dial_tests.rs|fn mysql_enforce_denies_loopback_metadata_and_names_resolving_to_them" \
  "mysql/dial_tests.rs|fn mysql_shadow_logs_would_deny_and_dials_unchanged" \
  "mysql/dial_tests.rs|fn mysql_pinned_opts_dial_only_the_vetted_ip" \
  "mysql/dial_tests.rs|fn mysql_revet_moves_the_pin_to_the_new_vetted_ip" \
  "mysql/dial_tests.rs|fn mysql_adapter_refuses_tenant_dsns_and_passes_platform" \
  "redis/dial_tests.rs|fn redis_adapter_refuses_tenant_dsns_and_passes_platform" \
  "redis/dial_tests.rs|fn redis_unix_socket_is_refused_under_enforce_and_logged_under_shadow" \
  "redis/dial_tests.rs|fn redis_pins_the_vetted_ip_not_the_name" \
  "redis/dial_tests.rs|fn redis_revets_after_the_interval_and_rebuilds_on_change" \
  "redis/dial_tests.rs|fn redis_refusal_never_repeats_the_password" \
  "mssql/dial_tests.rs|fn mssql_routing_hop_is_vetted_and_pinned_under_enforce" \
  "mssql/dial_tests.rs|fn mssql_routing_to_a_denied_host_is_refused_under_enforce" \
  "mssql/dial_tests.rs|fn mssql_routing_to_a_denied_host_is_logged_under_shadow" \
  "mssql/dial_tests.rs|fn mssql_second_redirect_is_an_error" \
  "mssql/dial_tests.rs|fn mssql_named_instance_is_refused_under_enforce" \
  "mssql/dial_tests.rs|fn mssql_adapter_refuses_tenant_dsns_and_passes_platform" \
  "mssql/dial_tests.rs|fn mssql_refusal_never_repeats_the_password" \
  "dynamodb_dial_tests.rs|fn dynamodb_resolver_vets_every_lookup_under_enforce" \
  "dynamodb_dial_tests.rs|fn dynamodb_resolver_logs_and_returns_the_records_under_shadow" \
  "dynamodb_dial_tests.rs|fn dynamodb_sdk_connection_to_a_denied_name_is_refused_under_enforce" \
  "dynamodb_dial_tests.rs|fn dynamodb_sdk_connection_to_a_denied_name_is_logged_under_shadow" \
  "dynamodb_dial_tests.rs|fn dynamodb_adapter_client_vets_each_connection" \
  "dynamodb_dial_tests.rs|fn dynamodb_adapter_refuses_tenant_dsns_and_passes_platform" \
  "dynamodb_dial_tests.rs|fn dynamodb_tenant_without_static_keys_is_logged_not_refused_under_shadow" \
  "dynamodb_dial_tests.rs|fn dynamodb_refusal_never_repeats_the_keys" \
  "canary.rs|fn a_dial_guard_refusal_never_repeats_the_password"; do
  grep -qF -- "${pair#*|}" "${POOL}/${pair%%|*}" || fail "missing ${pair%%|*}:${pair#*|}"
done
need "${SERVER}/config.rs" 'Some\(ConfigError::UnknownDialGuardMode\)' "the startup refusal is untested"
pass "39 test anchors + the config refusal"

step "static: the approximations are named, the allowlist stays out (C13)"
for f in dial_guard/scope.rs postgres/dial.rs mysql/dial.rs redis/dial.rs mssql/dial.rs dynamodb_dial.rs; do
  need "${POOL}/${f}" 'Caveat:' "${f} carries no Caveat"
done
! grep -rq 'DATA_PLANE_DIAL_ALLOW_CIDRS' "${CRATES}" || fail "a subnet allowlist reached the code (BLOCKED, C13)"
need "${ROOT}/docs/adr/0019-g2-dial-guard.md" '^## D1' "ADR 0019 does not say what D1 delivered"
need "${ROOT}/docs/adr/0019-g2-dial-guard.md" '^## D3a' "ADR 0019 does not say what D3a delivered"
need "${ROOT}/docs/adr/0019-g2-dial-guard.md" '^## D2' "ADR 0019 does not say what D2 delivered"
need "${ROOT}/docs/adr/0019-g2-dial-guard.md" '^## D4' "ADR 0019 does not say what D4 delivered"
[ -f "${ROOT}/.out-of-scope/dial-guard-subnet-allowlist.md" ] || fail "the out-of-scope note for the allowlist is gone"
pass "6 Caveats, no allowlist, ADR + out-of-scope present"

printf '\033[32mm244 passed (static)\033[0m\n'
