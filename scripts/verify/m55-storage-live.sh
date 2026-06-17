#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m55-storage-live.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M55 — Storage DX live e2e gate (A1). Proves, against the RUNNING mini-baas
# stack through Kong, that the storage feature is actually live AND owner-safe:
#
#   1. createBucket    POST /storage/v1/bucket/<name> → 201 (idempotent).
#   2. upload          PUT  /storage/v1/object/<bucket>/<key> stores a KNOWN
#                      binary payload (NUL + 0xff bytes — not just ASCII).
#   3. list            GET  /storage/v1/list/<bucket> → the object appears
#                      (server strips the owner prefix from the returned key).
#   4. download        GET  /storage/v1/object/<bucket>/<key> → the bytes
#                      ROUND-TRIP byte-identical to what was uploaded (cmp).
#   5. createSignedUrl POST /storage/v1/sign/...; GET the presigned S3 URL
#                      returns the SAME bytes (the real direct-S3 path). The
#                      signed URL targets the internal endpoint (minio:9000,
#                      SignedHeaders=host), so the GET runs inside a container
#                      on the stack network — rewriting the host would break
#                      the SigV4 signature, so we must dial the signed host.
#   6. owner isolation a DIFFERENT identity (its own JWT `sub`) cannot list or
#                      read our object — list returns no key, download 404s.
#   7. forged-header   the foreign identity ALSO forging X-User-Id /
#                      X-Baas-Tenant-Id = OUR sub still sees nothing: Kong's
#                      global pre-function clears client X-User-* and only the
#                      verified JWT sub may set it, so the forgery is inert.
#   +  anon-reject     anon-key-only (no JWT) upload is 401 — storage requires
#                      a verified user identity.
#
# Identity model (discovered): the storage-router AuthGuard runs in `compat`
# mode (container env IDENTITY_HEADER_MODE=compat, overriding NODE_ENV) and
# reads the legacy X-User-Id header → identity.userId → user.id. Kong's global
# pre-function STRIPS any client X-User-* up front, then sets X-User-Id from the
# verified JWT `sub`; storage.service auto-prefixes every object key with that
# user id (`<userId>/<path>`), which is the owner-isolation boundary. The gate
# mints its JWT with `sub = <tenant slug>` so the owner namespace is a single,
# inspectable value; the foe JWT carries a different sub.
#
# The byte round-trip (steps 4+5) and the isolation/forged-header negatives
# (steps 6+7) are the teeth: a broken upload/download path fails cmp, and a
# broken owner-scope makes the foe's empty-list / 404 assertions trip.
#
# Requires the stack up with the storage plane (mini-baas-{storage-router,kong,
# minio}). Pure-pg lib-live-tenant provisions the scratch tenant; the signed-URL
# GET uses a throwaway curlimages/curl container on the stack network.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M55] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M55] FAIL — $*"; exit 1; }

# shellcheck source=scripts/lib/lib-live-tenant.sh
source "${SCRIPT_DIR}/../lib/lib-live-tenant.sh"

TMP="$(mktemp -d)"
SLUG="m55st$(date +%s)$$"
BUCKET="m55b$(date +%s)$$"

cleanup() {
  # best-effort: remove our objects, then let the lib soft-delete the tenant.
  if [[ -n "${KONG:-}" && -n "${ANON:-}" && -n "${JWT:-}" ]]; then
    for k in dir/note.bin sg.bin; do
      curl -s -o /dev/null -X DELETE "${KONG}/storage/v1/object/${BUCKET}/${k}" \
        -H "apikey: ${ANON}" -H "Authorization: Bearer ${JWT}" 2>/dev/null || true
    done
  fi
  live_tenant_cleanup 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

# Mint an HS256 JWT (iss=supabase → the Kong `supabase` jwt_secret consumer;
# the global pre-function decodes `sub` into X-User-Id, the storage owner key).
mint_jwt() { # secret sub
  python3 - "$1" "$2" <<'PY'
import sys, hmac, hashlib, base64, json, time
secret, sub = sys.argv[1], sys.argv[2]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
hdr = b64(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(',',':')).encode())
pl  = b64(json.dumps({"iss":"supabase","sub":sub,"role":"authenticated",
                      "email":sub+"@m55.local","exp":int(time.time())+3600},
                     separators=(',',':')).encode())
sig = b64(hmac.new(secret.encode(), hdr+b'.'+pl, hashlib.sha256).digest())
print((hdr+b'.'+pl+b'.'+sig).decode())
PY
}

# ── 0) prerequisites: tenant + JWTs + storage network ────────────────────────
step "0/7 prerequisites (tenant, JWTs, stack network)"
live_tenant_provision "${SLUG}" || fail "tenant provisioning failed"
KONG="${LIVE_KONG_URL}"; ANON="${LIVE_ANON_APIKEY}"

JWT_SECRET="$(_lt_env mini-baas-gotrue GOTRUE_JWT_SECRET)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(_lt_env mini-baas-kong JWT_SECRET)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(_lt_env mini-baas-storage-router JWT_SECRET)"
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET="$(grep -E '^JWT_SECRET=' "${BAAS_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
[[ -n "${JWT_SECRET}" ]] || fail "could not discover JWT_SECRET"
JWT="$(mint_jwt "${JWT_SECRET}" "${SLUG}")"
FOE_JWT="$(mint_jwt "${JWT_SECRET}" "m55foe-${SLUG}")"

STACK_NET="$(docker inspect mini-baas-minio \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)"
[[ -n "${STACK_NET}" ]] || fail "could not discover the minio stack network"
ok "tenant '${SLUG}', JWT minted (sub=slug), foe JWT minted, net ${STACK_NET}"

# curl helpers: body→/tmp/m55.json, echo status. as_user = our JWT; as_foe =
# foreign JWT; as_anon = apikey only (no bearer JWT).
as_user() { curl -s -o /tmp/m55.json -w '%{http_code}' -X "$1" "${KONG}$2" -H "apikey: ${ANON}" -H "Authorization: Bearer ${JWT}" "${@:3}"; }
as_foe()  { curl -s -o /tmp/m55.json -w '%{http_code}' -X "$1" "${KONG}$2" -H "apikey: ${ANON}" -H "Authorization: Bearer ${FOE_JWT}" "${@:3}"; }
has()  { grep -q "$1" /tmp/m55.json || fail "$2: response missing $1 — $(head -c 300 /tmp/m55.json)"; }
nhas() { grep -q "$1" /tmp/m55.json && fail "$2: response leaked $1 — $(head -c 300 /tmp/m55.json)"; return 0; }

# Known binary payload — NUL + high bytes prove the path is byte-clean, not
# text-mangled. printf %b emits the escapes literally.
printf '%b' 'm55-storage-\x00\x01\x02\xfe\xff-payload-roundtrip-tail' > "${TMP}/up.bin"
UP_SHA="$(sha256sum "${TMP}/up.bin" | cut -d' ' -f1)"
OBJ="dir/note.bin"

# ── 1) createBucket ──────────────────────────────────────────────────────────
step "1/7 createBucket"
[[ "$(as_user POST "/storage/v1/bucket/${BUCKET}")" == "201" ]] || fail "createBucket — $(head -c 300 /tmp/m55.json)"
has "\"name\":\"${BUCKET}\"" "createBucket name"
has '"created":true' "createBucket created flag"
ok "bucket ${BUCKET} created"

# ── 2) upload a known byte payload ───────────────────────────────────────────
step "2/7 upload (known binary payload)"
[[ "$(as_user PUT "/storage/v1/object/${BUCKET}/${OBJ}" \
      -H 'Content-Type: application/octet-stream' --data-binary @"${TMP}/up.bin")" == "200" ]] \
  || fail "upload — $(head -c 300 /tmp/m55.json)"
# Server reports the owner-prefixed key + the exact byte count.
has "\"key\":\"${SLUG}/${OBJ}\"" "upload owner-prefixed key"
has '"size":' "upload size"
ok "uploaded ${OBJ} ($(wc -c < "${TMP}/up.bin") bytes, owner-prefixed to ${SLUG}/)"

# ── 3) list → the object appears ─────────────────────────────────────────────
step "3/7 list → object appears (owner prefix stripped)"
[[ "$(as_user GET "/storage/v1/list/${BUCKET}")" == "200" ]] || fail "list — $(head -c 300 /tmp/m55.json)"
has "\"key\":\"${OBJ}\"" "list shows our object (prefix stripped)"
nhas "${SLUG}/" "list must NOT leak the raw owner prefix in keys"
ok "object listed as ${OBJ}"

# ── 4) download → bytes round-trip byte-identical ────────────────────────────
step "4/7 download → byte round-trip (the teeth)"
code="$(curl -s -o "${TMP}/dl.bin" -w '%{http_code}' \
        "${KONG}/storage/v1/object/${BUCKET}/${OBJ}" \
        -H "apikey: ${ANON}" -H "Authorization: Bearer ${JWT}")"
[[ "${code}" == "200" ]] || fail "download status ${code}"
cmp -s "${TMP}/up.bin" "${TMP}/dl.bin" \
  || fail "download bytes differ from upload — sha up=${UP_SHA} dl=$(sha256sum "${TMP}/dl.bin" | cut -d' ' -f1)"
ok "downloaded bytes IDENTICAL to upload (sha256 ${UP_SHA})"

# ── 5) createSignedUrl → GET the signed URL returns the same bytes ───────────
step "5/7 createSignedUrl → presigned GET round-trips bytes"
[[ "$(as_user POST "/storage/v1/sign/${BUCKET}/${OBJ}" \
      -H 'Content-Type: application/json' -d '{"method":"GET","expiresIn":300}')" == "201" ]] \
  || fail "createSignedUrl — $(head -c 300 /tmp/m55.json)"
has '"signedUrl":' "sign returns a url"
has "\"key\":\"${SLUG}/${OBJ}\"" "sign owner-prefixed key"
SIGNED_URL="$(python3 -c 'import json;print(json.load(open("/tmp/m55.json"))["signedUrl"])')"
[[ -n "${SIGNED_URL}" ]] || fail "no signedUrl in response"
# SigV4 signs the Host header → fetch the signed host verbatim from inside the
# stack network (rewriting minio:9000 would invalidate the signature). Stream
# to stdout → host file: the curl image runs as a non-root uid that can't write
# a bind-mounted host dir, and `-f` makes a bad/expired signature a hard fail
# (proven: tampering the X-Amz-Signature returns 4xx → curl exit 22).
docker run --rm --network "${STACK_NET}" curlimages/curl:latest \
  -s -f -o - "${SIGNED_URL}" > "${TMP}/signed.bin" \
  || fail "presigned GET failed (url targets ${SIGNED_URL%%\?*})"
cmp -s "${TMP}/up.bin" "${TMP}/signed.bin" \
  || fail "presigned-GET bytes differ from upload — sha=$(sha256sum "${TMP}/signed.bin" | cut -d' ' -f1)"
ok "presigned URL serves the SAME bytes (sha256 ${UP_SHA})"

# ── 6) owner isolation — a different identity sees nothing ───────────────────
step "6/7 owner isolation (foreign identity)"
[[ "$(as_foe GET "/storage/v1/list/${BUCKET}")" == "200" ]] || fail "foe list call — $(head -c 300 /tmp/m55.json)"
nhas "\"key\":\"${OBJ}\"" "foreign user must NOT see our object in list"
nhas "${SLUG}/" "foreign list must NOT reveal our owner namespace"
foe_dl="$(as_foe GET "/storage/v1/object/${BUCKET}/${OBJ}")"
[[ "${foe_dl}" == "404" ]] || fail "foreign download of our object should be 404, got ${foe_dl} — $(head -c 200 /tmp/m55.json)"
ok "foreign identity: list empty + download 404 (owner-scoped)"

# ── 7) forged-header reject — foe forging our identity still sees nothing ────
step "7/7 forged-header reject (foe forges our X-User-Id / tenant)"
# Kong's pre-function clears client X-User-* and only the verified JWT sub may
# set it, so a forged X-User-Id = our slug must be inert: the foe's sub still
# scopes the request.
[[ "$(as_foe GET "/storage/v1/list/${BUCKET}" \
      -H "X-User-Id: ${SLUG}" -H "X-Baas-Tenant-Id: ${SLUG}" -H "X-Tenant-Id: ${SLUG}")" == "200" ]] \
  || fail "foe forged-header list call — $(head -c 300 /tmp/m55.json)"
nhas "\"key\":\"${OBJ}\"" "forged X-User-Id must NOT reveal our object"
foe_forge_dl="$(as_foe GET "/storage/v1/object/${BUCKET}/${OBJ}" \
      -H "X-User-Id: ${SLUG}" -H "X-Baas-Tenant-Id: ${SLUG}")"
[[ "${foe_forge_dl}" == "404" ]] \
  || fail "foe forging our X-User-Id read our object (got ${foe_forge_dl}) — Kong header-clear regressed"
ok "forged X-User-Id/tenant inert: foe still sees nothing (Kong strips client identity)"

# ── +) anon-only (no JWT) upload is rejected ─────────────────────────────────
step "+/7 anon-key-only (no JWT) upload is rejected"
anon_code="$(curl -s -o /tmp/m55.json -w '%{http_code}' -X PUT \
        "${KONG}/storage/v1/object/${BUCKET}/anon.bin" \
        -H "apikey: ${ANON}" -H 'Content-Type: application/octet-stream' --data-binary 'nope')"
[[ "${anon_code}" == "401" ]] || fail "anon-only upload should be 401, got ${anon_code} — $(head -c 200 /tmp/m55.json)"
ok "no identity → 401 (storage requires an authenticated user)"

green "[M55] ALL GATES GREEN — storage DX fully live: bucket · upload · list · byte-round-trip download · presigned-URL round-trip · owner isolation (+forged-header reject) · anon-reject"
