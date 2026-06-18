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

cyan "[deps] Rust — cargo audit (data-plane-router)"
docker run --rm -v "${RUST_WS}":/work -w /work \
  -v mini-baas-cargo-registry:/usr/local/cargo/registry -v mini-baas-cargo-git:/usr/local/cargo/git \
  -v mini-baas-cargo-bin:/usr/local/cargo/bin "${RUST_IMG}" sh -c "
    command -v cargo-audit >/dev/null 2>&1 || cargo install cargo-audit --locked -q
    cargo audit ${RUST_IGNORE}
  " || {
  red "[deps] cargo audit found a NEW vulnerability"
  rc=1
}

cyan "[deps] Go — govulncheck (control-plane, reachability-based)"
docker run --rm -v "${GO_DIR}":/work -w /work \
  -v mini-baas-go-build-cache:/go/pkg/mod -e GOFLAGS=-mod=mod "${GO_IMG}" sh -c '
    go install golang.org/x/vuln/cmd/govulncheck@latest >/dev/null 2>&1
    /go/bin/govulncheck ./...
  ' || {
  red "[deps] govulncheck found a vulnerability"
  rc=1
}

[[ "${rc}" == "0" ]] && green "[deps] OK — no new vulnerabilities (Go clean; Rust transitive advisories tracked)" ||
  red "[deps] FAIL — see above"
exit "${rc}"
