#!/usr/bin/env bash
# ============================================================
# m175 — Protected-namespace isolation (collab: spaces)
#
# Closes the realtime gap where a wildcard / namespace-less token (granted
# `["*"]` by the permissive fallback or the NoAuth provider) could SUBSCRIBE to
# any `collab:<spaceId>` topic — reading a Shared space it was never added to.
#
# Fix (flag-gated, REALTIME_PROTECTED_NAMESPACES, default EMPTY = byte-parity):
# a `"*"` grant no longer covers a protected-prefix namespace; reaching it needs
# an EXACT namespace grant. Collab members already present `["collab:<id>"]`
# scoped tokens (minted by the membership-gated bridge), so they are unaffected;
# everyone else loses wildcard reach into `collab:` ONLY (chat/feed/live-DB keep
# their wildcard, so there is NO breaking global deny flip).
#
# This gate exercises the authorization decision directly via the realtime-core
# unit test (the pure can_subscribe_to_scoped / can_publish_to_scoped logic),
# plus the byte-parity tests that prove an empty protected list is unchanged.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RT="$ROOT/infra/docker/services/realtime/realtime-agnostic"
IMG="mini-baas-rust-toolchain"
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

printf '\033[1m── m175: protected-namespace isolation (collab:) ──\033[0m\n'

docker image inspect "$IMG" >/dev/null 2>&1 || make -C "$ROOT" _rust-toolchain >/dev/null

CARGO="docker run --rm -v $RT:/work -w /work \
  -v mini-baas-cargo-registry:/usr/local/cargo/registry \
  -v mini-baas-cargo-git:/usr/local/cargo/git \
  -v mini-baas-realtime-target:/work/target $IMG cargo"

$CARGO test -p realtime-core protected_namespace_excludes_wildcard 2>&1 | tail -3 \
  | grep -qE '1 passed' || fail "protected-prefix wildcard exclusion test failed"
ok "wildcard token cannot reach a protected collab: namespace; exact grant still can"

$CARGO test -p realtime-core auth_claims 2>&1 | tail -3 \
  | grep -qE '[2-9] passed|[0-9]{2,} passed' || fail "byte-parity auth_claims tests regressed"
ok "empty protected list is byte-parity (existing subscribe/deny semantics unchanged)"

printf '\033[1;32mm175 PASS\033[0m — collab: spaces are isolated from wildcard tokens (flag-gated, default OFF)\n'
