#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m51-multinode.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M51 — multi-instance rate-limit correctness (Track-2 C1).
#
# The ratelimit-redis backend (now in the data-plane default features) makes the
# per-tenant limit AUTHORITATIVE across replicas: N data-plane instances must
# draw from ONE shared Redis bucket, else a tenant bursts its tier once per
# replica. This proves it WITHOUT standing up N containers + Kong LB — two
# RedisRateLimiter instances on the same live Redis are two replicas by
# construction; the integration test asserts their COMBINED admits ≈ the burst,
# not a per-replica multiple. (The container-scale variant — compose --scale +
# the scale overlay's container_name removal — is the operator soak; this is the
# reproducible unit of correctness.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ROUTER_DIR="${BAAS_DIR}/docker/services/data-plane-router"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M51] $*"; }
pass()  { green "[M51] PASS: $*"; }
fail()  { red "[M51] FAIL: $*"; exit 1; }
skip()  { printf '\033[1;33m[M51] SKIP: %s\033[0m\n' "$*"; exit 0; }

NET=mini-baas_mini-baas
docker inspect -f '{{.State.Running}}' mini-baas-redis 2>/dev/null | grep -q true \
  || skip "mini-baas-redis not running (start a stack: make up)"
docker network inspect "${NET}" >/dev/null 2>&1 || skip "network ${NET} absent"

step "two RedisRateLimiter instances, one live Redis — assert ONE global bucket"
OUT=/tmp/m51-cargo.log
set +e
docker run --rm --network "${NET}" \
  -e REDIS_URL=redis://redis:6379 \
  -e CARGO_TERM_COLOR=never \
  -v "${ROUTER_DIR}":/work -w /work \
  -v mini-baas-cargo-registry:/usr/local/cargo/registry \
  -v mini-baas-cargo-git:/usr/local/cargo/git \
  -v mini-baas-dpr-target:/work/target \
  public.ecr.aws/docker/library/rust:1.89-slim-bookworm \
  cargo test -p data-plane-server --features ratelimit-redis \
    redis_backend_is_one_global_bucket_across_instances -- --nocapture \
  >"${OUT}" 2>&1
rc=$?
set -e

grep -E 'test result|SKIP|panicked|admitted' "${OUT}" | tail -6 || true
[ ${rc} -eq 0 ] || { tail -15 "${OUT}"; fail "multinode rate-limit test failed"; }
grep -q 'SKIP .*REDIS_URL unset' "${OUT}" && fail "test skipped — REDIS_URL not seen inside the container"
grep -qE 'test result: ok\. 1 passed' "${OUT}" || { tail -15 "${OUT}"; fail "expected 1 passing test"; }
pass "shared global bucket proven — replicas cannot multiply a tenant's tier burst"

green "[M51] ALL GATES GREEN — ratelimit-redis enforces one authoritative limit across instances"
