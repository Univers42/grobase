#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m43-one-files.sh                                   :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/12 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/12 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M43 — binocle-one file storage gate:
#   1. image budget ≤ 12 MB with multipart + the image crate compiled in;
#   2. multipart PNG upload as a user → 201 + metadata; bytes round-trip;
#   3. owner-scoping: another user can't see it (404), admin key can; the
#      owner's list shows it, the stranger's list is empty;
#   4. ?thumb=WxH returns a real downscaled PNG (dimensions verified);
#   5. protected link: minted token grants unauthenticated GET; garbage 401s;
#   6. caps: oversize upload 413 (ONE_MAX_FILE_MB=1), text/html 415,
#      path-traversal coordinates 400;
#   7. delete: stranger 404, owner 204, bytes gone after;
#   8. idle RSS ≤ 15 MiB.

set -euo pipefail
cyan(){ printf '\033[0;36m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*"; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
step(){ cyan "[M43] $*"; }
fail(){ red "[M43] FAIL — $*"; cleanup; exit 1; }
ok(){ green "  ✓ $*"; }

IMAGE="${ONE_IMAGE:-binocle-one}"
NAME="m43-one-$$"
PORT="${ONE_PORT:-18944}"
KEY="m43-admin-$(date +%s)-deterministic"
BASE="http://127.0.0.1:${PORT}"
TMP="$(mktemp -d)"

cleanup(){ docker rm -fv "${NAME}" >/dev/null 2>&1 || true; rm -rf "${TMP}"; }
trap cleanup EXIT

req(){ # method path auth body → body<TAB>status
  local method="$1" path="$2" auth="$3" body="${4:-}"
  local args=(-s -w $'\t%{http_code}' -X "${method}" "${BASE}${path}" -H "Content-Type: application/json")
  [[ -n "${auth}" ]] && args+=(-H "${auth}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}"
}
status_of(){ awk -F'\t' '{print $NF}' <<<"$1"; }
jget(){ python3 -c "import sys,json;d=json.loads(sys.stdin.read().rsplit('\t',1)[0]);print($1)" <<<"$2"; }

step "0/8 boot + ≤12 MB budget"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || fail "image '${IMAGE}' not built (make one-build)"
IMG_MB=$(( $(docker image inspect --format '{{.Size}}' "${IMAGE}") / 1024 / 1024 ))
(( IMG_MB <= 12 )) || fail "image ${IMG_MB} MB > 12 MB budget"
docker run -d --name "${NAME}" -p "${PORT}:8090" \
  -e NANO_ADMIN_KEY="${KEY}" -e ONE_MAX_FILE_MB=1 "${IMAGE}" >/dev/null
for i in $(seq 1 20); do
  curl -sf "${BASE}/v1/health" >/dev/null 2>&1 && break
  [[ $i -eq 20 ]] && fail "binocle-one never came up"
  sleep 0.5
done
ok "image ${IMG_MB} MB ≤ 12 MB; server up (ONE_MAX_FILE_MB=1)"

step "1/8 register two users + craft a real PNG"
R=$(req POST /one/v1/auth/register "" '{"email":"hank@local.dev","password":"hank-pass-1234"}')
TOK_H=$(jget "d['token']" "$R")
R=$(req POST /one/v1/auth/register "" '{"email":"iris@local.dev","password":"iris-pass-1234"}')
TOK_I=$(jget "d['token']" "$R")
python3 -c "
import struct, zlib
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
w = h = 64
raw = b''.join(b'\x00' + bytes(3) * w for _ in range(h))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open('${TMP}/pic.png', 'wb').write(png)
"
ok "hank + iris registered; 64x64 PNG crafted"

step "2/8 upload + byte round-trip"
R=$(curl -s -w $'\t%{http_code}' -X POST "${BASE}/one/v1/files/notes/n1/attachment" \
  -H "Authorization: Bearer ${TOK_H}" \
  -F "file=@${TMP}/pic.png;type=image/png")
[[ "$(status_of "$R")" == "201" ]] || fail "upload: $R"
FID=$(jget "d['file']['id']" "$R")
[[ "$(jget "d['file']['size']" "$R")" -gt 0 ]] || fail "size not recorded: $R"
curl -s -o "${TMP}/back.png" -H "Authorization: Bearer ${TOK_H}" "${BASE}/one/v1/file/${FID}"
cmp -s "${TMP}/pic.png" "${TMP}/back.png" || fail "bytes differ after round-trip"
CT=$(curl -s -o /dev/null -w '%{content_type}' -H "Authorization: Bearer ${TOK_H}" "${BASE}/one/v1/file/${FID}")
[[ "${CT}" == image/png* ]] || fail "content-type: ${CT}"
ok "201 + exact byte round-trip + image/png"

step "3/8 owner-scoping + admin escape"
# Binary bodies break the tab-parsing req helper — status-only curls here.
get_status(){ curl -s -o /dev/null -w '%{http_code}' -H "$2" "${BASE}$1"; }
[[ "$(get_status "/one/v1/file/${FID}" "Authorization: Bearer ${TOK_I}")" == "404" ]] || fail "stranger must 404"
[[ "$(get_status "/one/v1/file/${FID}" "X-Baas-Api-Key: ${KEY}")" == "200" ]] || fail "admin key read failed"
R=$(req GET "/one/v1/files/notes/n1" "Authorization: Bearer ${TOK_H}")
[[ "$(jget "len(d['files'])" "$R")" == "1" ]] || fail "owner list: $R"
R=$(req GET "/one/v1/files/notes/n1" "Authorization: Bearer ${TOK_I}")
[[ "$(jget "len(d['files'])" "$R")" == "0" ]] || fail "stranger list must be empty: $R"
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/one/v1/file/${FID}")" == "401" ]] || fail "anonymous must 401"
ok "owner sees it, stranger 404/empty, admin key reads, anonymous 401"

step "4/8 thumbnail is a real downscale"
curl -s -o "${TMP}/thumb.png" -H "Authorization: Bearer ${TOK_H}" "${BASE}/one/v1/file/${FID}?thumb=16x16"
python3 -c "
import struct, sys
d = open('${TMP}/thumb.png','rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
w, h = struct.unpack('>II', d[16:24])
assert (w, h) == (16, 16), f'thumb is {w}x{h}'
" || fail "thumbnail wrong"
R=$(req GET "/one/v1/file/${FID}?thumb=9999x2" "Authorization: Bearer ${TOK_H}")
[[ "$(status_of "$R")" == "400" ]] || fail "oversize thumb spec must 400: $R"
ok "16x16 thumbnail verified; spec clamped"

step "5/8 protected file token"
R=$(req POST "/one/v1/file/${FID}/token" "Authorization: Bearer ${TOK_H}")
[[ "$(status_of "$R")" == "200" ]] || fail "mint token: $R"
FTOK=$(jget "d['token']" "$R")
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/one/v1/file/${FID}?token=${FTOK}")" == "200" ]] || fail "token GET failed"
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/one/v1/file/${FID}?token=garbage")" == "401" ]] || fail "garbage token must 401"
R=$(req POST "/one/v1/file/${FID}/token" "Authorization: Bearer ${TOK_I}")
[[ "$(status_of "$R")" == "404" ]] || fail "stranger can't mint tokens: $R"
ok "signed link works unauthenticated; garbage rejected; minting owner-only"

step "6/8 caps: oversize 413, html 415, traversal 400"
head -c 1200000 /dev/zero > "${TMP}/big.bin"
R=$(curl -s -w $'\t%{http_code}' -o /dev/null -X POST "${BASE}/one/v1/files/notes/n1/big" \
  -H "Authorization: Bearer ${TOK_H}" \
  -F "file=@${TMP}/big.bin;type=application/octet-stream")
[[ "${R##*$'\t'}" == "413" ]] || fail "oversize must 413: ${R}"
R=$(curl -s -w $'\t%{http_code}' -o /dev/null -X POST "${BASE}/one/v1/files/notes/n1/page" \
  -H "Authorization: Bearer ${TOK_H}" \
  -F "file=@${TMP}/pic.png;type=text/html")
[[ "${R##*$'\t'}" == "415" ]] || fail "text/html must 415: ${R}"
R=$(curl -s -w $'\t%{http_code}' -o /dev/null -X POST "${BASE}/one/v1/files/..%2F..%2Fetc/n1/f" \
  -H "Authorization: Bearer ${TOK_H}" \
  -F "file=@${TMP}/pic.png;type=image/png")
[[ "${R##*$'\t'}" == "400" ]] || fail "traversal coordinate must 400: ${R}"
ok "413 / 415 / 400 enforced"

step "7/8 delete: stranger 404, owner 204, gone after"
R=$(req DELETE "/one/v1/file/${FID}" "Authorization: Bearer ${TOK_I}")
[[ "$(status_of "$R")" == "404" ]] || fail "stranger delete must 404: $R"
R=$(req DELETE "/one/v1/file/${FID}" "Authorization: Bearer ${TOK_H}")
[[ "$(status_of "$R")" == "204" ]] || fail "owner delete: $R"
R=$(req GET "/one/v1/file/${FID}" "Authorization: Bearer ${TOK_H}")
[[ "$(status_of "$R")" == "404" ]] || fail "file must be gone: $R"
ok "delete lifecycle correct"

step "8/8 idle RSS ≤ 15 MiB"
sleep 2
MEM_TOKEN=$(docker stats --no-stream --format '{{.MemUsage}}' "${NAME}" | awk '{print $1}')
MEM_MIB=$(awk -v v="${MEM_TOKEN}" 'BEGIN{u=v; sub(/[0-9.]+/,"",u); n=v; sub(/[A-Za-z]+/,"",n); n=n+0;
  if(u=="GiB") printf "%.1f", n*1024; else if(u=="KiB") printf "%.3f", n/1024; else printf "%.1f", n}')
awk -v m="${MEM_MIB}" 'BEGIN{exit !(m<=15)}' || fail "idle RSS ${MEM_MIB} MiB > 15 MiB budget"
ok "idle RSS ${MEM_MIB} MiB ≤ 15 MiB"

green "[M43] ALL GATES GREEN — binocle-one files: ${IMG_MB} MB image, ${MEM_MIB} MiB idle — multipart upload, owner-scoped serve, real thumbnails, signed links, caps, delete"
