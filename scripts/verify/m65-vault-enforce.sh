#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m65-vault-enforce.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M65 — G-Vault (A6) live gate. Proves the control plane (adapter-registry)
# REQUIRES a Vault-backed master credential at SECURITY_MODE=max and FAILS
# CLOSED — refuses to boot, with a clear error and NO silent fallback to an
# env/placeholder value — when that secret is absent; and that the DEFAULT mode
# is byte-parity (boots exactly as today regardless of Vault).
#
# The enforced boot hook (control-plane internal/shared/config.go LoadConfig →
# requireVaultBackedCredentials):
#     if mode != "max" { return nil }              // OFF = byte-parity short-circuit
#     if VAULT_ENC_KEY is absent / a known placeholder / too short -> error
#     if neither VAULT_ADDR nor VAULT_CREDENTIAL_SOURCE=vault       -> error
# LoadConfig returns the error BEFORE the Postgres connect; main() logs it and
# os.Exit(1). So the negative arm needs no DB — the refusal happens at config.
#
# ISOLATED by design (mirrors m72's isolated-ephemeral style): a scratch
# adapter-registry built FROM THE CURRENT (drafted, uncommitted) source + a
# throwaway postgres, both on a PRIVATE network, every container/image/network
# name suffixed with $$, an EXIT-trap that removes EVERYTHING. It NEVER touches a
# mini-baas-* container, network, image, or volume — safe while the live stack is
# up. Uses plain `docker run` (no compose project name that could collide with
# mini-baas-*). No host ports for the data path — only loopback-bound publish for
# the health probe.
#
#   (1) NEGATIVE / FAIL-CLOSED: boot SECURITY_MODE=max with NO Vault creds
#       (placeholder VAULT_ENC_KEY, no VAULT_ADDR) -> the container MUST exit
#       NON-ZERO and its logs MUST carry the explicit "SECURITY_MODE=max requires
#       a Vault-backed VAULT_ENC_KEY" refusal. It MUST NOT serve /health/live.
#   (2) POSITIVE: boot SECURITY_MODE=max WITH a real key + VAULT_ADDR + a scratch
#       postgres -> the container MUST stay up and serve /health/live -> 200.
#   (3) PARITY:   boot the DEFAULT SECURITY_MODE with the SAME placeholder key +
#       postgres -> it MUST boot and serve /health/live -> 200 (Vault not
#       required; live baseline byte-identical).
#
# Fails (exit≠0) if (1) serves / exits 0 / lacks the refusal, or if (2)/(3) fail
# to serve. Each fail names the exact assertion that tripped. PASS is logged via
# .claude/lib/log.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"          # mini-baas-infra
CP_DIR="${BAAS_DIR}/go/control-plane"
REPO_BAAS_DIR="$(cd "${BAAS_DIR}/.." && pwd)"          # apps/baas (for .claude/lib/log.sh)
LOG_HELPER="${REPO_BAAS_DIR}/.claude/lib/log.sh"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M65] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M65] FAIL — $*"; exit 1; }

PG_IMAGE="${M65_PG_IMAGE:-postgres:16-alpine}"
SCRATCH_IMG="m65-ar-$$:scratch"
NET="m65net-$$"
PG="m65-pg-$$"
AR_NEG="m65-ar-neg-$$"     # (1) NEGATIVE arm  — max, no Vault creds → fail closed
AR_POS="m65-ar-pos-$$"     # (2) POSITIVE arm  — max, real key + VAULT_ADDR → serves
AR_PAR="m65-ar-par-$$"     # (3) PARITY arm    — default mode, placeholder key → serves
PORT_POS="${M65_PORT_POS:-18965}"
PORT_PAR="${M65_PORT_PAR:-18966}"
PGPW="postgres"
DSN_INNET="postgres://postgres:${PGPW}@${PG}:5432/postgres"

# The publicly-known compose placeholder (docker-compose.yml VAULT_ENC_KEY
# default-of-last-resort) — the exact value max mode must refuse.
PLACEHOLDER_ENC_KEY="0123456789abcdef0123456789abcdef"
# A real per-deployment secret (≥16 chars, NOT a placeholder) standing in for a
# value resolved from Vault in the positive arm.
REAL_ENC_KEY="m65-real-vault-sourced-master-key-$$"
# A strong internal service token so the existing weak-token guard never trips
# (we are testing the Vault guard, not that one).
SVC_TOKEN="m65-strong-service-token-$$"

# The substring the fail-closed error MUST contain (config.go refusal message).
REFUSAL_SUBSTR="SECURITY_MODE=max requires a Vault-backed"

cleanup() {
  docker rm -fv "${AR_NEG}" "${AR_POS}" "${AR_PAR}" "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${SCRATCH_IMG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Probe /health/live on a router on 127.0.0.1:$port; echo HTTP status (000 if down).
health_code() { # $1=port
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$1/health/live" 2>/dev/null || echo 000
}

wait_serving() { # $1=container  $2=port  -> 0 if it serves /health/live=200
  for _ in $(seq 1 60); do
    [[ "$(health_code "$2")" == "200" ]] && return 0
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true || {
      red "$1 exited before serving:"; docker logs "$1" 2>&1 | tail -15; return 1; }
    sleep 0.5
  done
  red "$1 never served /health/live:"; docker logs "$1" 2>&1 | tail -15; return 1
}

# Wait for a container to EXIT; echo its exit code (or "running" if still up after
# the budget — a fail-closed boot must exit promptly).
wait_exit() { # $1=container -> stdout: exit code | "running"
  for _ in $(seq 1 40); do
    local running; running="$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo true)"
    [[ "${running}" == "false" ]] && { docker inspect -f '{{.State.ExitCode}}' "$1"; return 0; }
    sleep 0.25
  done
  echo running
}

# ── 0) build the scratch adapter-registry image FROM THE CURRENT (drafted) source ─
step "0/6 build scratch adapter-registry from CURRENT source (contains THE A6 boot guard)"
DOCKER_BUILDKIT=1 docker build -q \
  --build-arg APP=adapter-registry --build-arg PORT=3021 \
  -f "${CP_DIR}/Dockerfile" -t "${SCRATCH_IMG}" "${CP_DIR}" >/dev/null \
  || fail "scratch adapter-registry image build failed — the gate must exercise the drafted code (line: docker build)"
ok "scratch image ${SCRATCH_IMG} built from $(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree"

# ── 1) isolated network + throwaway postgres (for the boot-completing arms) ────
step "1/6 boot isolated postgres (${PG}) on private net (${NET})"
docker network create "${NET}" >/dev/null
docker run -d --name "${PG}" --network "${NET}" -e POSTGRES_PASSWORD="${PGPW}" "${PG_IMAGE}" >/dev/null
# Alpine entrypoint inits then RESTARTS once ("ready" twice) — wait for the 2nd.
for i in $(seq 1 80); do
  [[ "$(docker logs "${PG}" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]] && break
  [[ $i -eq 80 ]] && fail "throwaway postgres never reached its post-init steady state (line: PG ready loop)"
  sleep 0.5
done
# adapter-registry's EnsureSchema creates an RLS policy that calls
# auth.current_tenant_id() — a function the live stack provides via gotrue +
# db-bootstrap. Seed the minimal prerequisite (the `auth` schema + a stub
# function) so the BOOT-COMPLETING arms (POSITIVE/PARITY) reach the listen step.
# This is test scaffolding for the runtime dependency, NOT part of the A6 change.
seed_auth() {
  docker exec -i "${PG}" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS text
  LANGUAGE sql STABLE AS $fn$ SELECT current_setting('request.tenant_id', true) $fn$;
SQL
}
for i in $(seq 1 20); do seed_auth && break; [[ $i -eq 20 ]] && fail "auth-schema seed never committed (line: seed_auth loop)"; sleep 0.5; done
ok "postgres up on the private network (auth.current_tenant_id() stub seeded)"

# ── 2) (1) NEGATIVE / FAIL-CLOSED arm: max + NO Vault creds → MUST refuse boot ─
# No DB env beyond DATABASE_URL is needed: the Vault guard fires in LoadConfig
# BEFORE the Postgres connect. We still point at the real DSN so that — if the
# guard were (wrongly) absent — the service WOULD boot, making a passing negative
# arm impossible to fake. --restart=no so a crash-loop can't mask the exit code.
step "2/6 boot adapter-registry SECURITY_MODE=max with NO Vault creds (1 · NEGATIVE / fail-closed)"
docker run -d --name "${AR_NEG}" --network "${NET}" --restart=no \
  -e SECURITY_MODE=max \
  -e VAULT_ENC_KEY="${PLACEHOLDER_ENC_KEY}" \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  "${SCRATCH_IMG}" >/dev/null
NEG_EXIT="$(wait_exit "${AR_NEG}")"
[[ "${NEG_EXIT}" != "running" ]] \
  || fail "NEGATIVE: container is STILL RUNNING under SECURITY_MODE=max with a placeholder VAULT_ENC_KEY — it did NOT fail closed (line: NEG still running)"
[[ "${NEG_EXIT}" != "0" ]] \
  || fail "NEGATIVE: container exited 0 under SECURITY_MODE=max with no Vault creds — fail-closed means a NON-ZERO exit (line: NEG exit 0)"
ok "container exited NON-ZERO (${NEG_EXIT}) — it refused to boot"

step "2b/6 ASSERT (1): the refusal names the explicit Vault requirement (clear error, no silent fallback)"
NEG_LOGS="$(docker logs "${AR_NEG}" 2>&1)"
grep -q "${REFUSAL_SUBSTR}" <<<"${NEG_LOGS}" \
  || fail "NEGATIVE: logs lack the explicit refusal '${REFUSAL_SUBSTR}' — $(tail -5 <<<"${NEG_LOGS}") (line: NEG refusal substr)"
# It must NOT have silently fallen back and started listening.
grep -qiE 'listening' <<<"${NEG_LOGS}" \
  && fail "NEGATIVE: the service logged 'listening' — it silently fell back instead of failing closed (line: NEG listening leak)"
ok "logs carry the explicit '${REFUSAL_SUBSTR} VAULT_ENC_KEY' refusal and the service never started listening"

# ── 3) (1) confirm it truly never served (refused, not merely slow) ───────────
step "3/6 ASSERT (1): the NEGATIVE service never served /health/live"
NEG_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${AR_NEG}" 2>/dev/null || true)"
# It already exited, so there is nothing to curl — assert via a fresh probe from
# inside the net that nothing answers on 3021 for that (now-dead) container.
docker run --rm --network "${NET}" "${PG_IMAGE}" \
  sh -c "timeout 2 sh -c 'echo > /dev/tcp/${AR_NEG}/3021' 2>/dev/null" \
  && fail "NEGATIVE: something is still listening on ${AR_NEG}:3021 — it did not fail closed (line: NEG port open)" \
  || ok "nothing listens for the refused container — fail-closed confirmed"

# ── 4) (2) POSITIVE arm: max + real key + VAULT_ADDR + postgres → MUST serve ──
step "4/6 boot adapter-registry SECURITY_MODE=max WITH a real key + VAULT_ADDR (2 · POSITIVE)"
docker run -d --name "${AR_POS}" --network "${NET}" \
  -e SECURITY_MODE=max \
  -e VAULT_ENC_KEY="${REAL_ENC_KEY}" \
  -e VAULT_ADDR="http://vault.invalid:8200" \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -p "127.0.0.1:${PORT_POS}:3021" "${SCRATCH_IMG}" >/dev/null
wait_serving "${AR_POS}" "${PORT_POS}" \
  || fail "POSITIVE: SECURITY_MODE=max with a real Vault-backed key did NOT serve — the positive path is broken (line: POS wait_serving)"
POS_CODE="$(health_code "${PORT_POS}")"
[[ "${POS_CODE}" == "200" ]] \
  || fail "POSITIVE: /health/live returned ${POS_CODE}, expected 200 (line: POS health code)"
ok "SECURITY_MODE=max with a real Vault-backed key BOOTS and serves /health/live=200"

# ── 5) (3) PARITY arm: default mode + SAME placeholder key + postgres → serves ─
# The byte-parity proof: with SECURITY_MODE unset (default baseline), the EXACT
# placeholder key that the negative arm rejected at max is accepted as today.
step "5/6 boot adapter-registry DEFAULT SECURITY_MODE with the SAME placeholder key (3 · PARITY)"
docker run -d --name "${AR_PAR}" --network "${NET}" \
  -e VAULT_ENC_KEY="${PLACEHOLDER_ENC_KEY}" \
  -e DATABASE_URL="${DSN_INNET}" \
  -e INTERNAL_SERVICE_TOKEN="${SVC_TOKEN}" \
  -p "127.0.0.1:${PORT_PAR}:3021" "${SCRATCH_IMG}" >/dev/null
wait_serving "${AR_PAR}" "${PORT_PAR}" \
  || fail "PARITY: default SECURITY_MODE did NOT boot on the placeholder key — the default is NOT byte-parity! (line: PAR wait_serving)"
PAR_CODE="$(health_code "${PORT_PAR}")"
[[ "${PAR_CODE}" == "200" ]] \
  || fail "PARITY: /health/live returned ${PAR_CODE}, expected 200 (line: PAR health code)"
# And the parity boot must NOT have logged the max-mode refusal.
PAR_LOGS="$(docker logs "${AR_PAR}" 2>&1)"
grep -q "${REFUSAL_SUBSTR}" <<<"${PAR_LOGS}" \
  && fail "PARITY: default mode logged the max-mode Vault refusal — the guard leaked into the default path (line: PAR refusal leak)"
ok "default SECURITY_MODE BOOTS and serves on the SAME placeholder key (Vault not required) — live baseline byte-parity"

# ── 6) cross-check: the ONLY difference between (1) and (3) is SECURITY_MODE ───
step "6/6 cross-check: SAME placeholder key — max REFUSES (1), default SERVES (3)"
[[ "${NEG_EXIT}" != "0" && "${NEG_EXIT}" != "running" && "${PAR_CODE}" == "200" ]] \
  || fail "arm outcomes inconsistent (NEG exit=${NEG_EXIT}, PARITY health=${PAR_CODE}) (line: cross-check)"
ok "SECURITY_MODE=max is the SOLE gate on the Vault-backed-credential requirement"

green "[M65] ALL GATES GREEN — SECURITY_MODE=max FAILS CLOSED (non-zero exit + explicit '${REFUSAL_SUBSTR} VAULT_ENC_KEY' refusal, no silent fallback) when Vault creds are absent; BOOTS+serves with a real Vault-backed key; DEFAULT mode boots on the placeholder = byte-parity live baseline"

# ── log PASS via the kernel helper (JSONL; never hand-rolled) ─────────────────
if [[ -f "${LOG_HELPER}" ]]; then
  # shellcheck source=/dev/null
  if AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-A6-vault}" \
       source "${LOG_HELPER}" 2>/dev/null; then
    log_event GATE --outcome PASS --ref m65-vault-enforce \
      --gate "m65-vault-enforce=PASS" \
      --msg "SECURITY_MODE=max requires Vault-backed VAULT_ENC_KEY and fails closed (non-zero exit + explicit refusal); default mode byte-parity" \
      >/dev/null 2>&1 || true
  fi
fi
