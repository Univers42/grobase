#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    audit-deps.sh                                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/11 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# Supply-chain vulnerability scan (audit report solution #3): cargo-audit for the
# Rust data plane + govulncheck for the Go control plane, containerized. Exits
# non-zero on a NEW vulnerability so it can gate CI.
#
# The Rust transitive advisories listed in RUST_IGNORE are ACCEPTED-WITH-
# REMEDIATION: rustls-webpki 0.101 comes solely from tiberius 0.12 (its rustls
# 0.21 chain; 0.12.3 IS the latest release — no upstream fix exists yet) and is
# only reachable for EXTERNAL TLS mssql mounts. The mongodb 2.8 share (idna +
# its webpki path) was CLEARED by the mongodb 3.x bump. Remediation = bump
# tiberius when a rustls-0.2x release lands (tracked in wiki/security-audit.md).
# Ignoring keeps the gate meaningful (a *new* vuln still fails) without a noisy
# permanent red.
#
# Three more transitive WARNINGS (unmaintained/unsound, not active CVEs) are
# accepted on the same basis — none is in the default-feature tree or reachable
# on a code path we drive, and none has a fix we control:
#   RUSTSEC-2025-0134  rustls-pemfile 2.2.0 unmaintained — deprecated upstream
#       (folded into rustls-pki-types); only on the feature-gated external-TLS
#       chain. Remediation = drops out when the TLS stack bumps.
#   RUSTSEC-2026-0002  lru 0.12.5 unsound IterMut — pulled SOLELY by mysql_async
#       0.34 for its internal stmt cache; we never call IterMut. Remediation =
#       bump when mysql_async releases against a patched lru.
#   RUSTSEC-2026-0097  rand 0.7.3 unsound — feature-gated transitive; the unsound
#       path needs a custom logger calling rand::rng(), which we don't do.
#       Remediation = parent crate bump to rand 0.8.
set -uo pipefail

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUST_WS="${ROOT}/src/data-plane-router"
GO_DIR="${ROOT}/src/control-plane"
RUST_IMG="mini-baas-rust-toolchain"
GO_IMG="golang:1.25-bookworm"

# rustls-webpki x3 (cert name-constraint / CRL) — transitive via tiberius only.
RUST_IGNORE="--ignore RUSTSEC-2026-0098 --ignore RUSTSEC-2026-0099 --ignore RUSTSEC-2026-0104"
# rustls-pemfile unmaintained · lru unsound (mysql_async) · rand 0.7 unsound — see header.
RUST_IGNORE="${RUST_IGNORE} --ignore RUSTSEC-2025-0134 --ignore RUSTSEC-2026-0002 --ignore RUSTSEC-2026-0097"

rc=0
OUT="$(mktemp -d)"
trap 'rm -rf "${OUT}"' EXIT

# gha_error TITLE FILE — under GitHub Actions, a ::error annotation naming the advisory ids
# (or the first error line) in FILE, so a red run says why (annotations are public).
gha_error() {
  [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
  local why
  why="$(grep -oE '(RUSTSEC-[0-9]{4}-[0-9]{4}|GO-[0-9]{4}-[0-9]{4}|GHSA-[a-z0-9-]+)' "$2" | sort -u | tr '\n' ' ')"
  [ -n "${why}" ] || why="$(grep -m2 -iE 'error' "$2" | tr '\n' ' ' | cut -c1-300)"
  printf '::error title=%s::%s\n' "$1" "${why:-see job log}"
}

cyan "[deps] Rust — cargo audit (data-plane-router)"
docker run --rm -v "${RUST_WS}":/work -w /work \
  -v mini-baas-cargo-registry:/usr/local/cargo/registry -v mini-baas-cargo-git:/usr/local/cargo/git \
  -v mini-baas-cargo-bin:/usr/local/cargo/bin "${RUST_IMG}" sh -c "
    command -v cargo-audit >/dev/null 2>&1 || cargo install cargo-audit --locked -q
    cargo audit ${RUST_IGNORE}
  " 2>&1 | tee "${OUT}/cargo-audit.log" || {
  red "[deps] cargo audit found a NEW vulnerability"
  gha_error "cargo audit" "${OUT}/cargo-audit.log"
  rc=1
}

cyan "[deps] Go — govulncheck (control-plane, reachability-based)"
# govulncheck v1.8+ needs go >= 1.26; pin the last release GO_IMG can build. An install
# failure exits 99 so it is never mistaken for a finding (exit 3) or a clean scan (0).
GOVULN_VER="v1.7.0"
govuln_rc=0
docker run --rm -v "${GO_DIR}":/work -w /work \
  -v mini-baas-go-build-cache:/go/pkg/mod -e GOFLAGS=-mod=mod "${GO_IMG}" sh -c "
    go install golang.org/x/vuln/cmd/govulncheck@${GOVULN_VER} || exit 99
    /go/bin/govulncheck ./...
  " 2>&1 | tee "${OUT}/govulncheck.log" || govuln_rc=${PIPESTATUS[0]}
[ "${govuln_rc}" = 0 ] || gha_error "govulncheck (exit ${govuln_rc})" "${OUT}/govulncheck.log"
case "${govuln_rc}" in
0) ;;
3)
  red "[deps] govulncheck found a vulnerability"
  rc=1
  ;;
99)
  red "[deps] govulncheck ${GOVULN_VER} could not be installed — the Go scan did NOT run"
  rc=1
  ;;
*)
  red "[deps] govulncheck errored (exit ${govuln_rc}) — the Go scan result is unknown"
  rc=1
  ;;
esac

[[ "${rc}" == "0" ]] && green "[deps] OK — no new vulnerabilities (Go clean; Rust transitive advisories tracked)" ||
  red "[deps] FAIL — see above"
exit "${rc}"
