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
# Supply-chain scan (audit report solution #3), containerized: cargo-deny over BOTH Rust
# workspaces (data-plane-router and the vendored realtime-agnostic) + govulncheck for the Go
# control plane. Exits non-zero on a NEW finding so it can gate CI.
#
# cargo-deny checks four things against scripts/security/deny.toml: advisories (RustSec,
# unsoundness anywhere in the graph), licences (permissive only: the core is AGPL and also
# sold commercially under CLA.md), crate sources (crates.io only) and wildcard versions.
# The accepted transitive advisories and the reason for each live in deny.toml.
#
# Ponytail: the pinned cargo-deny binary is the x86_64 musl build; on an arm64 host the fetch
# succeeds but the container cannot exec it (the step fails, never passes). Use the aarch64
# asset and its sha256 there.
set -uo pipefail

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUST_WORKSPACES=("${ROOT}/src/data-plane-router" "${ROOT}/infra/docker/services/realtime/realtime-agnostic")
GO_DIR="${ROOT}/src/control-plane"
RUST_IMG="mini-baas-rust-toolchain"
GO_IMG="golang:1.26-bookworm"

DENY_VER="0.20.2"
DENY_SHA256="9f12ed4c49936e09b48bf862b595cde2fe64fcbd9d74dfacac6131ca824c8d5f"
DENY_URL="https://github.com/EmbarkStudios/cargo-deny/releases/download/${DENY_VER}/cargo-deny-${DENY_VER}-x86_64-unknown-linux-musl.tar.gz"

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

# fetch_cargo_deny DIR — download the pinned cargo-deny release into DIR/cargo-deny and
# check it against DENY_SHA256 (pinned here, not read from the release it verifies).
fetch_cargo_deny() {
  curl -fsSL --retry 3 -o "$1/cargo-deny.tgz" "${DENY_URL}" &&
    echo "${DENY_SHA256}  $1/cargo-deny.tgz" | sha256sum -c --quiet - &&
    tar -xzf "$1/cargo-deny.tgz" -C "$1" --strip-components=1 \
      "cargo-deny-${DENY_VER}-x86_64-unknown-linux-musl/cargo-deny"
}

# cargo_deny WORKSPACE — every cargo-deny check on one workspace, under deny.toml. The
# advisory database is cached in a volume shared by both workspaces.
cargo_deny() {
  docker run --rm -v "$1":/work:ro -w /work -v "${OUT}/cargo-deny":/usr/local/bin/cargo-deny:ro \
    -v "${SCRIPT_DIR}/deny.toml":/deny.toml:ro \
    -v mini-baas-cargo-registry:/usr/local/cargo/registry -v mini-baas-cargo-git:/usr/local/cargo/git \
    -v mini-baas-advisory-dbs:/usr/local/cargo/advisory-dbs "${RUST_IMG}" \
    cargo-deny --color never --config /deny.toml --locked check
}

if fetch_cargo_deny "${OUT}"; then
  for ws in "${RUST_WORKSPACES[@]}"; do
    cyan "[deps] Rust — cargo deny (${ws#"${ROOT}"/})"
    cargo_deny "${ws}" 2>&1 | tee "${OUT}/cargo-deny.log" || {
      red "[deps] cargo deny failed for ${ws#"${ROOT}"/}"
      gha_error "cargo deny (${ws##*/})" "${OUT}/cargo-deny.log"
      rc=1
    }
  done
else
  red "[deps] cargo-deny ${DENY_VER} could not be fetched or verified — the Rust scan did NOT run"
  rc=1
fi

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

[[ "${rc}" == "0" ]] && green "[deps] OK — no new findings (Go clean; Rust: accepted advisories are in deny.toml)" ||
  red "[deps] FAIL — see above"
exit "${rc}"
