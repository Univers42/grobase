#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m24-tenant-owned.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Gate for milestone M24 step 1: the `tenant_owned` isolation mode + Postgres
# TLS — the two platform capabilities that let an EXTERNAL client database
# (vite-gourmand's Supabase project) be mounted live:
#
#   tenant_owned   the mount is wholly one tenant's pre-existing database:
#                  writes skip the owner_id inject/filter, DDL skips the
#                  owner_id synthesis, upserts arbitrate on caller keys only.
#                  SAFETY: tenant gating still happens at key→mount
#                  resolution — a foreign tenant's key never resolves the
#                  mount. Unknown isolation strings STILL degrade to
#                  shared_rls (parity invariant); mysql/mongo FAIL CLOSED
#                  (NotImplemented) instead of silently owner-scoping.
#   TLS            DSNs carrying sslmode=require/verify-* get a rustls
#                  connector (libpq `require` semantics: encrypt, no chain
#                  verification — Supabase certs chain to a project CA);
#                  every other DSN keeps the NoTls path byte-identical.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
ROUTER_DIR="${BAAS_DIR}/docker/services/data-plane-router"
GO_DIR="${BAAS_DIR}/go/control-plane"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M24] FAIL: $*"; exit 1; }
step()  { cyan "[M24] ${*}"; }
pass()  { green "[M24] PASS: ${*}"; }

# ── 1) isolation core: the 4th mode + the owner_scoped predicate ─────────────
step "checking the Isolation::TenantOwned contract"
ISO_RS="${ROUTER_DIR}/crates/data-plane-core/src/isolation.rs"
grep -q "TenantOwned" "${ISO_RS}" || fail "Isolation::TenantOwned missing"
grep -q 'Some("tenant_owned") => Self::TenantOwned' "${ISO_RS}" \
  || fail "from_mount does not parse tenant_owned"
grep -q "pub fn owner_scoped" "${ISO_RS}" || fail "owner_scoped() predicate missing"
grep -q "_ => Self::SharedRls" "${ISO_RS}" \
  || fail "unknown isolation must STILL degrade to SharedRls (parity invariant)"
pass "TenantOwned parsed, owner_scoped() declared, unknown→SharedRls preserved"

# ── 2) postgres: every owner site gated; mysql/mongo fail closed ────────────
step "checking the engine owner-scoping gates"
PG_RS="${ROUTER_DIR}/crates/data-plane-pool/src/postgres.rs"
grep -q "fn owner_predicate" "${PG_RS}" || fail "pg owner_predicate helper missing"
grep -q "owner: Option<&str>" "${PG_RS}" || fail "pg builders must take Option<&str> owner"
grep -q "owner_scoped.then_some" "${PG_RS}" || fail "pg runners must derive owner from owner_scoped"
grep -q "owner_scoped && !has_owner" "${PG_RS}" || fail "pg DDL owner synthesis must be gated"
grep -q "self.isolation.owner_scoped()" "${PG_RS}" || fail "pg execute/txn must consult the pool isolation"
for engine in mysql mongo; do
  grep -q "tenant_owned isolation on this engine" \
    "${ROUTER_DIR}/crates/data-plane-pool/src/${engine}.rs" \
    || fail "${engine} must fail closed on tenant_owned (NotImplemented)"
done
pass "pg writes/DDL/txn gated on owner_scoped(); mysql/mongo fail closed"

# ── 3) TLS: rustls connector behind sslmode, NoTls path intact ───────────────
step "checking the Postgres TLS connector"
# dsn_wants_tls evolved into effective_tls_mode (adds the SECURITY_MODE=max
# require→verify upgrade); either name proves the sslmode parser is present.
grep -qE "fn (dsn_wants_tls|effective_tls_mode)" "${PG_RS}" || fail "sslmode parser (effective_tls_mode) missing"
grep -q "fn rustls_connector" "${PG_RS}" || fail "rustls_connector missing"
grep -q "tokio_postgres_rustls::MakeRustlsConnect" "${PG_RS}" || fail "MakeRustlsConnect not used"
grep -q "cfg.create_pool(Some(Runtime::Tokio1), NoTls)" "${PG_RS}" \
  || fail "the NoTls branch must remain for local mounts"
grep -q 'tokio-postgres-rustls' "${ROUTER_DIR}/Cargo.toml" || fail "workspace dep missing"
pass "sslmode-gated rustls connector present; NoTls branch intact"

# ── 4) control plane: registry accepts tenant_owned, CHECK widened ───────────
step "checking the Go adapter-registry"
grep -q '"tenant_owned": true' "${GO_DIR}/internal/adapterregistry/models.go" \
  || fail "allowedIsolation must accept tenant_owned"
grep -q "DROP CONSTRAINT IF EXISTS tenant_databases_isolation_check" \
  "${GO_DIR}/internal/adapterregistry/service.go" \
  || fail "EnsureSchema must widen the isolation CHECK idempotently"
pass "registry accepts tenant_owned; CHECK constraint widened idempotently"

# ── 5) unit suites ───────────────────────────────────────────────────────────
# Run the two crates SEQUENTIALLY (not `-p core -p pool` in one invocation):
# the pool test binary pulls the heavy rustls/mongodb/mysql build, and running
# both binaries' threads concurrently has intermittently starved a pure core
# planner test under CI memory pressure. Sequential = deterministic; both
# suites still gate.
step "running cargo + go test suites"
docker run --rm -v "${PWD}/${ROUTER_DIR}":/work -w /work rust:1.89-slim \
  sh -c 'cargo test -p data-plane-core 2>&1 | tail -8 && echo "===POOL===" && cargo test -p data-plane-pool 2>&1 | tail -12' \
  > /tmp/m24-cargo.log 2>&1 || fail "cargo tests failed: $(grep -E 'FAILED|error' /tmp/m24-cargo.log | head -3)"
grep -q "test result: FAILED" /tmp/m24-cargo.log && fail "cargo test failures: $(tail -5 /tmp/m24-cargo.log)"
docker run --rm -v "${PWD}/${GO_DIR}":/work -w /work golang:1.25-bookworm \
  sh -c 'go test ./internal/adapterregistry/ 2>&1 | tail -3' \
  > /tmp/m24-go.log 2>&1 || fail "go tests failed: $(tail -3 /tmp/m24-go.log)"
grep -q '^ok' /tmp/m24-go.log || fail "go test did not report ok: $(cat /tmp/m24-go.log)"
pass "cargo (core+pool) and go (adapterregistry) suites green"

green "[M24] OK — tenant_owned isolation + Postgres TLS verified"
