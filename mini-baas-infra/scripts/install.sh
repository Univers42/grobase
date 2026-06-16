#!/bin/sh
# **************************************************************************** #
# install.sh — binocle single-binary installer (Grobase BaaS)
#
#   curl -fsSL https://github.com/Univers42/groot/releases/download/baas-v1.1.0/install.sh | sh
#
# Downloads the binocle-one (default) or binocle-nano static binary from the
# GitHub Release, verifies its sha256, and unpacks it into the current
# directory. No Docker, no root, no dependencies beyond curl/sha256sum/tar.
#
# Options (env vars):
#   BINOCLE_VERSION=1.0.0   release to install (default pinned below — the
#                           monorepo hosts other products' releases, so
#                           "latest" is deliberately NOT used)
#   BINOCLE_EDITION=one     one (accounts/OAuth/MFA/files/admin UI) | nano (headless)
#
# Scope (v1.0): linux-amd64 only — the binaries are x86_64 static musl.
# **************************************************************************** #
set -eu

VERSION="${BINOCLE_VERSION:-1.1.0}"
EDITION="${BINOCLE_EDITION:-one}"
REPO="Univers42/groot"
TAG="baas-v${VERSION}"

say()  { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────────────
case "${EDITION}" in
  one|nano) : ;;
  *) fail "BINOCLE_EDITION must be 'one' or 'nano' (got '${EDITION}')" ;;
esac

OS="$(uname -s)"; ARCH="$(uname -m)"
[ "${OS}" = "Linux" ] || fail "binocle v${VERSION} ships Linux binaries only (got ${OS}). Use the Docker image instead: dlesieur/binocle-${EDITION}:${VERSION}"
case "${ARCH}" in
  x86_64|amd64) : ;;
  *) fail "binocle v${VERSION} ships linux-amd64 only (got ${ARCH}). arm64 is planned; meanwhile use the Docker image on an amd64 host." ;;
esac

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar  >/dev/null 2>&1 || fail "tar is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

# ── Download + verify ────────────────────────────────────────────────────────
ASSET="binocle-${EDITION}-${VERSION}-linux-amd64.tar.gz"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

say "→ Downloading ${ASSET} (${TAG}) ..."
curl -fsSL -o "${TMP}/${ASSET}"        "${BASE}/${ASSET}"        || fail "download failed: ${BASE}/${ASSET}"
curl -fsSL -o "${TMP}/${ASSET}.sha256" "${BASE}/${ASSET}.sha256" || fail "checksum download failed"

say "→ Verifying sha256 ..."
( cd "${TMP}" && sha256sum -c "${ASSET}.sha256" >/dev/null ) || fail "sha256 verification FAILED — refusing to install"

say "→ Unpacking ..."
tar -xzf "${TMP}/${ASSET}" -C .
chmod +x "binocle-${EDITION}"

# ── Done ─────────────────────────────────────────────────────────────────────
say ""
say "✓ binocle-${EDITION} v${VERSION} installed in $(pwd)"
say ""
say "  Run it:        ./binocle-${EDITION}"
if [ "${EDITION}" = "one" ]; then
  say "  Admin UI:      http://localhost:8090/_/   (admin key printed on FIRST boot only)"
else
  say "  Data API:      http://localhost:8090/data/v1   (admin key printed on FIRST boot only)"
fi
say "  Data lives in: ./data (override: NANO_DATA_DIR)"
say ""
say "  Full platform (Docker, all engines + realtime): git clone https://github.com/${REPO} && cd groot && make all-local"
say "  Docs:          https://github.com/${REPO}/tree/main/apps/baas/mini-baas-infra"
