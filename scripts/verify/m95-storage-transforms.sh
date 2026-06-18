#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m95-storage-transforms.sh                          :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M95 — Track-A residual A1: STORAGE image TRANSFORMS + bucket-level ABAC policy.
# Proves, against the storage-router built FROM CURRENT source on an ISOLATED
# private network (its own MinIO, no mini-baas-* touched), that:
#
#   (A) POSITIVE — image transform variant:
#       • upload a known 256×256 PNG (owner-scoped, X-User-Id=owner in compat mode)
#       • GET …/object/<bucket>/<key>?width=64&height=64&format=webp returns:
#           - Content-Type: image/webp                   (correctly typed)
#           - a VALID webp (magic 'RIFF'…'WEBP')          (real decode, not a stub)
#           - dims 64×64 (sharp inside-fit on a square)   (actually resized)
#           - FEWER bytes than the original PNG            (smaller — a real variant)
#       • bucket policy ALLOWS the owner (read + write) — the happy path is permitted.
#
#   (B) LOAD-BEARING REJECT — bucket policy denies, no leak:
#       With STORAGE_BUCKET_POLICY_ENABLED=1 and a policy that DENIES a foe user on
#       a locked bucket, the foe's transform/download request is 403 — the S3 op is
#       never reached, so the foe never learns the object exists (no byte leak). A
#       SEPARATE owner-isolation reject also holds: a DIFFERENT owner (own X-User-Id)
#       transforming the SAME path gets 404 (owner-prefix scoping), proving the
#       transform path inherits owner-scope exactly like the plain GET.
#
#   (C) PARITY — STORAGE_TRANSFORMS_ENABLED unset (+ no bucket policy):
#       The ENABLED container is STOPPED+REMOVED first (so it can't re-answer), a
#       fresh storage-router is booted with BOTH flags unset against the SAME MinIO
#       data, and the SAME `?width=64&height=64&format=webp` GET returns the ORIGINAL
#       PNG bytes BYTE-IDENTICAL (cmp) — the transform query is inert when OFF.
#
# Identity: storage-router runs IDENTITY_HEADER_MODE=compat, so the legacy
# X-User-Id header IS the owner key (the same boundary Kong sets from a verified JWT
# sub in prod). We call the router DIRECTLY on the private net (no Kong needed for an
# isolated gate); the owner-prefix + bucket-policy logic under test is identical.
#
# Fully LOCALLY-RUNNABLE: throwaway containers only (MinIO + the router image built
# here + curl/node helper containers), a $$-suffixed private network, and an EXIT
# trap that removes EVERYTHING. It NEVER touches a mini-baas-* container/network/
# image/volume and NEVER edits the live docker-compose.yml.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)" # mini-baas-infra
BAAS_DIR="$(cd "${INFRA_DIR}/.." && pwd)"      # apps/baas
SRC_DIR="${INFRA_DIR}/src"                     # NestJS build context
CLAUDE_DIR="$(cd "${BAAS_DIR}/.claude" 2>/dev/null && pwd || true)"

cyan() { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }
step() { cyan "[M95] $*"; }
ok() { green "  ✓ $*"; }
fail() {
  red "[M95] FAIL — $*"
  exit 1
}

MINIO_IMAGE="${M95_MINIO_IMAGE:-minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1}"
CURL_IMAGE="${M95_CURL_IMAGE:-curlimages/curl:latest}"
STORE_IMG="m95-storage-$$:scratch" # storage-router built from CURRENT source (has sharp)
NET="m95net-$$"
MINIO="m95-minio-$$"
STORE_ON="m95-store-on-$$"   # transforms + policy ENABLED
STORE_OFF="m95-store-off-$$" # PARITY arm (both flags unset)
MINIO_USER="minioadmin"
MINIO_PW="minioadmin"
OWNER="m95-owner-$$" # the object owner (X-User-Id)
FOE="m95-foe-$$"     # a different owner / policy-denied principal
BUCKET="m95b$$"
OBJ="pics/src.png"
STRONG_TOKEN="m95-strong-internal-svc-token-not-for-prod-0123456789ab"
# Bucket policy (A1): the locked bucket DENIES the foe; the owner is allowed.
BUCKET_POLICY="{\"${BUCKET}\":{\"deny\":[\"user:${FOE}\"],\"read\":[\"user:${OWNER}\"],\"write\":[\"user:${OWNER}\"]}}"

TMP="$(mktemp -d)"
# The storage image runs as a non-root `appuser`; the curl image as its own uid.
# Make the shared scratch dir world-writable so any container uid can write the
# generated PNG / fetched variant into the bind mount (host stays the owner).
chmod 0777 "${TMP}"

cleanup() {
  docker rm -fv "${STORE_ON}" "${STORE_OFF}" "${MINIO}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker image rm -f "${STORE_IMG}" >/dev/null 2>&1 || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

# curl from a throwaway container on the private net, with the scratch dir mounted
# at /work so `--data-binary @/work/<file>` (uploads) and `-o /work/<file>`
# (downloads) work. Two helpers: one returns the HTTP status, one writes the raw
# response bytes to a host file and returns the status.
curl_status() { # METHOD PATH [extra curl args...]   → echoes HTTP status code
  local m="$1" p="$2"
  shift 2
  docker run --rm --network "${NET}" -v "${TMP}":/work "${CURL_IMAGE}" \
    -s -o /dev/null -w '%{http_code}' -X "${m}" "http://${STORE_HOST}${p}" "$@"
}
curl_bytes() { # METHOD PATH OUTFILE(host ${TMP}/<f>) [extra curl args...]  → status to stdout
  local m="$1" p="$2" out="$3"
  shift 3
  local base
  base="$(basename "${out}")"
  # Body goes straight to /work/<base> (= host ${TMP}/<base>); status via -w. Keeps
  # body + status on separate channels so binary bytes are never corrupted.
  docker run --rm --network "${NET}" -v "${TMP}":/work "${CURL_IMAGE}" \
    -s -o "/work/${base}" -w '%{http_code}' -X "${m}" "http://${STORE_HOST}${p}" "$@"
}

# Run a node one-liner inside the storage image (it bundles sharp). No network is
# needed — it only does local image generation/decode against the mounted /work.
# WORKDIR stays /app so `require("sharp")` resolves the image's node_modules; the
# scripts reference files by their absolute /work paths.
node_in_store() { # SCRIPT
  docker run --rm -v "${TMP}":/work -w /app --entrypoint node \
    "${STORE_IMG}" -e "$1"
}

wait_health() { # host:port url-path tries container-name
  local i hostport="$1" path="$2" tries="${3:-60}" cname="${4:-}"
  for i in $(seq 1 "${tries}"); do
    if docker run --rm --network "${NET}" "${CURL_IMAGE}" -s -f -o /dev/null \
      "http://${hostport}${path}" 2>/dev/null; then return 0; fi
    # If the target container has died, stop early (don't burn the whole budget).
    [[ -n "${cname}" ]] && ! docker inspect "${cname}" >/dev/null 2>&1 && return 1
    sleep 0.5
  done
  return 1
}

boot_store() { # container_name [extra -e flags...]
  local name="$1"
  shift
  docker run -d --name "${name}" --network "${NET}" \
    -e PORT=3040 \
    -e IDENTITY_HEADER_MODE=compat \
    -e INTERNAL_SERVICE_TOKEN="${STRONG_TOKEN}" \
    -e S3_ENDPOINT="http://${MINIO}:9000" \
    -e S3_REGION=us-east-1 \
    -e S3_ACCESS_KEY="${MINIO_USER}" \
    -e S3_SECRET_KEY="${MINIO_PW}" \
    -e LOG_LEVEL=info \
    "$@" \
    "${STORE_IMG}" >/dev/null
}

# ── 0) build the storage-router FROM CURRENT source (the A1 transform+policy code) ─
step "0/8 build storage-router image from CURRENT source (real Dockerfile, APP=storage-router)"
DOCKER_BUILDKIT=1 docker build -q --build-arg APP=storage-router -t "${STORE_IMG}" "${SRC_DIR}" >/dev/null ||
  fail "storage-router image build failed — gate must exercise the drafted A1 code"
# Prove sharp is actually present in the built (pruned) prod image — the transform
# path is dead without it.
node_in_store 'const s=require("sharp");console.log("sharp",s.versions.sharp)' | grep -q '^sharp ' ||
  fail "sharp not loadable in the built storage-router image — transforms cannot work"
ok "image built ($(git -C "${BAAS_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?') + working tree); sharp present"

# ── 1) isolated network + MinIO ──────────────────────────────────────────────────
step "1/8 boot isolated net (${NET}): MinIO"
docker network create "${NET}" >/dev/null
docker run -d --name "${MINIO}" --network "${NET}" \
  -e MINIO_ROOT_USER="${MINIO_USER}" -e MINIO_ROOT_PASSWORD="${MINIO_PW}" \
  "${MINIO_IMAGE}" server /data >/dev/null
wait_health "${MINIO}:9000" "/minio/health/live" 80 "${MINIO}" || fail "scratch MinIO never went healthy"
ok "MinIO up + healthy on the private net"

# ── 2) generate a known 256×256 PNG locally (sharp in the storage image) ──────────
step "2/8 generate a known 256×256 source PNG (sharp)"
node_in_store '
  const sharp=require("sharp");
  sharp({create:{width:256,height:256,channels:3,background:{r:200,g:50,b:90}}})
    .png().toFile("/work/src.png").then(()=>console.log("ok")).catch(e=>{console.error(e);process.exit(1)});
' | grep -q ok || fail "could not generate source PNG"
[[ -s "${TMP}/src.png" ]] || fail "source PNG not written"
SRC_BYTES="$(wc -c <"${TMP}/src.png")"
SRC_SHA="$(sha256sum "${TMP}/src.png" | cut -d' ' -f1)"
ok "source PNG: ${SRC_BYTES} bytes (sha256 ${SRC_SHA:0:16}…)"

# ── 3) boot storage-router with transforms + bucket policy ENABLED ────────────────
step "3/8 boot storage-router (STORAGE_TRANSFORMS_ENABLED=1, STORAGE_BUCKET_POLICY_ENABLED=1)"
boot_store "${STORE_ON}" \
  -e STORAGE_TRANSFORMS_ENABLED=1 \
  -e STORAGE_BUCKET_POLICY_ENABLED=1 \
  -e STORAGE_BUCKET_POLICY="${BUCKET_POLICY}"
STORE_HOST="${STORE_ON}:3040"
wait_health "${STORE_HOST}" "/health/live" 80 "${STORE_ON}" ||
  {
    docker logs "${STORE_ON}" 2>&1 | tail -20
    fail "storage-router (ON) never went healthy"
  }
ok "storage-router (ON) healthy"

# ── 4) createBucket + upload the source PNG (owner-scoped, policy ALLOWS owner) ───
step "4/8 createBucket + upload source PNG as owner (policy ALLOWS owner write)"
c="$(curl_status POST "/storage/v1/bucket/${BUCKET}" -H "X-User-Id: ${OWNER}")"
[[ "${c}" == "201" || "${c}" == "200" ]] || fail "createBucket → ${c}"
c="$(curl_status PUT "/storage/v1/object/${BUCKET}/${OBJ}" \
  -H "X-User-Id: ${OWNER}" -H 'Content-Type: image/png' \
  --data-binary "@/work/src.png")"
[[ "${c}" == "200" ]] || {
  docker logs "${STORE_ON}" 2>&1 | tail -15
  fail "upload → ${c}"
}
ok "bucket created + source PNG uploaded (owner allowed)"

# ── 5) (A) POSITIVE: 64×64 webp variant is smaller + correctly typed + resized ────
step "5/8 (A) GET ?width=64&height=64&format=webp → valid, smaller, 64×64 webp"
st="$(curl_bytes GET "/storage/v1/object/${BUCKET}/${OBJ}?width=64&height=64&format=webp" \
  "${TMP}/variant.webp" -H "X-User-Id: ${OWNER}")"
[[ "${st}" == "200" ]] || {
  docker logs "${STORE_ON}" 2>&1 | tail -15
  fail "transform GET → ${st}"
}
VAR_BYTES="$(wc -c <"${TMP}/variant.webp")"
[[ "${VAR_BYTES}" -gt 0 ]] || fail "transform returned an empty body"
# webp magic: bytes 0-3 = 'RIFF', bytes 8-11 = 'WEBP'.
MAGIC0="$(head -c4 "${TMP}/variant.webp")"
MAGIC8="$(dd if="${TMP}/variant.webp" bs=1 skip=8 count=4 2>/dev/null)"
[[ "${MAGIC0}" == "RIFF" && "${MAGIC8}" == "WEBP" ]] ||
  fail "returned bytes are not a webp (magic '${MAGIC0}'/'${MAGIC8}')"
# Decode the variant with sharp and assert dims == 64×64 and format == webp.
node_in_store '
  const sharp=require("sharp");
  sharp("/work/variant.webp").metadata().then(m=>{
    if(m.format!=="webp"){console.error("format="+m.format);process.exit(1);}
    if(m.width!==64||m.height!==64){console.error("dims="+m.width+"x"+m.height);process.exit(1);}
    console.log("metaok "+m.format+" "+m.width+"x"+m.height);
  }).catch(e=>{console.error(e.message);process.exit(1)});
' | grep -q '^metaok webp 64x64$' || fail "variant is not a 64×64 webp (sharp metadata mismatch)"
[[ "${VAR_BYTES}" -lt "${SRC_BYTES}" ]] ||
  fail "variant (${VAR_BYTES}B) is NOT smaller than the source PNG (${SRC_BYTES}B) — not a real transform"
ok "(A) variant: valid webp · 64×64 · ${VAR_BYTES}B < ${SRC_BYTES}B (owner allowed by policy)"

# ── 6) (B) LOAD-BEARING REJECTS: policy-denied foe = 403; cross-owner = 404 ───────
step "6/8 (B) policy-denied foe → 403 (no leak); cross-owner transform → 404 (owner-scope)"
# (B1) the policy DENIES user:${FOE} on this bucket → 403 before any S3 op (no leak).
foe="$(curl_status GET "/storage/v1/object/${BUCKET}/${OBJ}?width=64&format=webp" -H "X-User-Id: ${FOE}")"
[[ "${foe}" == "403" ]] ||
  {
    docker logs "${STORE_ON}" 2>&1 | tail -15
    fail "policy-denied foe should be 403, got ${foe}"
  }
# A denied foe must ALSO be blocked on a plain (non-transform) GET — same authz gate.
foe_plain="$(curl_status GET "/storage/v1/object/${BUCKET}/${OBJ}" -H "X-User-Id: ${FOE}")"
[[ "${foe_plain}" == "403" ]] || fail "policy-denied foe plain GET should be 403, got ${foe_plain}"
# (B2) a DIFFERENT allowed owner (use a fresh bucket with no deny) transforming the
# SAME object PATH gets 404 — the owner-prefix makes the object invisible. This is
# the owner-scope reject independent of the policy. Use a policy that allows BOTH so
# the 404 is owner-scope (not policy) — we boot it on a 2nd bucket.
BUCKET2="m95c$$"
ALT_OWNER="m95-alt-$$"
c="$(curl_status POST "/storage/v1/bucket/${BUCKET2}" -H "X-User-Id: ${OWNER}")"
[[ "${c}" == "201" || "${c}" == "200" ]] || fail "createBucket2 → ${c}"
c="$(curl_status PUT "/storage/v1/object/${BUCKET2}/${OBJ}" \
  -H "X-User-Id: ${OWNER}" -H 'Content-Type: image/png' --data-binary "@/work/src.png")"
[[ "${c}" == "200" ]] || fail "upload to bucket2 → ${c}"
# bucket2 has NO policy entry → owner-scope alone governs. ALT_OWNER transforming the
# owner's path must 404 (its own prefix has no such object).
alt="$(curl_status GET "/storage/v1/object/${BUCKET2}/${OBJ}?width=64&format=webp" -H "X-User-Id: ${ALT_OWNER}")"
[[ "${alt}" == "404" ]] ||
  {
    docker logs "${STORE_ON}" 2>&1 | tail -15
    fail "cross-owner transform should be 404 (owner-scope), got ${alt}"
  }
ok "(B) foe policy-denied → 403 (transform + plain, no leak); cross-owner transform → 404 (owner-scope)"

# ── 7) (C) PARITY: flags unset → SAME query returns the ORIGINAL bytes byte-identical
step "7/8 (C) STOP the ENABLED router, boot a fresh one with BOTH flags unset (PARITY)"
# Stop+REMOVE the ENABLED router FIRST so it can't answer; the OFF router shares the
# SAME MinIO data (same volume-less container, same backing store on the net).
docker rm -f "${STORE_ON}" >/dev/null 2>&1 || true
boot_store "${STORE_OFF}" # NO transform / NO policy flags → defaults OFF
STORE_HOST="${STORE_OFF}:3040"
wait_health "${STORE_HOST}" "/health/live" 80 "${STORE_OFF}" ||
  {
    docker logs "${STORE_OFF}" 2>&1 | tail -20
    fail "storage-router (OFF) never went healthy"
  }
# The SAME transform query, with the flag OFF, must return the ORIGINAL PNG verbatim.
st="$(curl_bytes GET "/storage/v1/object/${BUCKET}/${OBJ}?width=64&height=64&format=webp" \
  "${TMP}/parity.bin" -H "X-User-Id: ${OWNER}")"
[[ "${st}" == "200" ]] || {
  docker logs "${STORE_OFF}" 2>&1 | tail -15
  fail "parity GET → ${st}"
}
cmp -s "${TMP}/src.png" "${TMP}/parity.bin" ||
  fail "(C) flag-OFF transform query did NOT return the original bytes — sha src=${SRC_SHA} got=$(sha256sum "${TMP}/parity.bin" | cut -d' ' -f1)"
PARITY_CT="$(docker run --rm --network "${NET}" "${CURL_IMAGE}" -s -o /dev/null -w '%{content_type}' \
  "http://${STORE_HOST}/storage/v1/object/${BUCKET}/${OBJ}?width=64&height=64&format=webp" -H "X-User-Id: ${OWNER}")"
[[ "${PARITY_CT}" == image/png* ]] ||
  fail "(C) flag-OFF should serve image/png (original), got '${PARITY_CT}' — NOT byte-parity"
# A foe under the OFF router is governed by owner-scope ONLY (no policy): foe sees 404
# (own prefix empty), NOT 403 — proving the policy is inert when its flag is OFF.
foe_off="$(curl_status GET "/storage/v1/object/${BUCKET}/${OBJ}" -H "X-User-Id: ${FOE}")"
[[ "${foe_off}" == "404" ]] ||
  fail "(C) with policy flag OFF the foe should be owner-scoped to 404, got ${foe_off} (policy leaked while OFF)"
ok "(C) flag OFF: same query → ORIGINAL PNG byte-identical (image/png); policy inert (foe 404 not 403) — byte-parity"

# ── 8) emit the gate event via the kernel log helper (best-effort) ────────────────
step "8/8 cross-check + log GATE m95=PASS"
green "[M95] (A) ENABLED: ?width=64&height=64&format=webp → valid 64×64 webp, ${VAR_BYTES}B < ${SRC_BYTES}B (owner allowed)"
green "[M95] (B) REJECT:  policy-denied foe → 403 (no leak) · cross-owner transform → 404 (owner-scope)"
green "[M95] (C) PARITY:  flags unset → same query returns the ORIGINAL PNG byte-identical · policy inert (foe 404)"

emit_gate_log() {
  (
    set +e
    [[ -n "${CLAUDE_DIR}" && -f "${CLAUDE_DIR}/lib/log.sh" ]] || exit 0
    export CLAUDE_LOG_DIR="${CLAUDE_LOG_DIR:-${CLAUDE_DIR}/logs}"
    export AGENT_ROLE="${AGENT_ROLE:-tester}" AGENT_TASK="${AGENT_TASK:-a1-storage-transforms}"
    # shellcheck disable=SC1091
    . "${CLAUDE_DIR}/lib/log.sh" >/dev/null 2>&1 || exit 0
    log_event GATE --gate "m95=PASS" --outcome pass \
      --msg "A1 storage transforms (sharp resize/reformat on the owner-scoped object GET) + bucket-level ABAC policy: positive 64x64 webp variant smaller+typed; policy-denied foe 403 + cross-owner 404 (no leak); flags OFF -> original bytes byte-identical + policy inert (byte-parity)" \
      --ref "scripts/verify/m95-storage-transforms.sh" >/dev/null 2>&1
    exit 0
  ) || true
}
emit_gate_log
ok "gate event emitted (best-effort)"

green "[M95] ALL GATES GREEN — storage transforms + bucket-ABAC: real smaller/typed/resized variant, policy+owner rejects (no leak), byte-parity when OFF"
exit 0
