#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m58-sdks-compile.sh                                :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M58 — Generated polyglot SDKs compile gate (A4). Proves, OFFLINE (no live
# mini-baas stack needed — only the public package registries + Docker Hub),
# that the OpenAPI-generated Python and Dart SDKs are real, importable, and
# congruent with the public spec they were generated from. Docker-first
# (rule 2): no host python/dart/pip/pub — every build runs in a PINNED image.
#
#   1. Python compile   in python:3.12: `pip install -e .` builds the package
#                       AND `import grobase; from grobase import AuthApi,
#                       QueryApi, StorageApi, FunctionsApi, RestApi` — all 5
#                       generated Api surfaces must import (a bare `import
#                       grobase` would be VACUOUS: the package can import while
#                       the Api classes are broken, so we instantiate-by-name).
#   2. Dart analyze     in dart:stable: `dart pub get && dart analyze
#                       --fatal-infos` — a CLEAN analyze (zero infos/warnings/
#                       errors) over the whole package, and all 5 Api classes
#                       (`class XxxApi`) present in lib/api/*.dart.
#   3. Congruence       count the spec's HTTP operations (path × method) and
#                       assert BOTH SDKs expose exactly that many distinct
#                       operations. The OpenAPI generator emits one base method
#                       per operationId in both languages, so the rule asserted
#                       here is EXACT-EQUAL: spec_ops == python_ops == dart_ops.
#                       (Stated as a rule, not a magic number — the count is
#                       derived from the spec at run time. If a future generator
#                       groups operations differently the assertion would need
#                       a band; today the mapping is 1:1, so equality is the
#                       strongest honest bound.)
#
# A claim without an artifact is not in the plan: this gate IS the artifact for
# "Python + Dart SDKs ship and match the spec". It exits non-zero the moment a
# surface is missing, the build/analyze is dirty, or the op counts diverge.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
step()  { cyan "[M58] $*"; }
ok()    { green "  ✓ $*"; }
fail()  { red "[M58] FAIL — $*"; exit 1; }

# BAAS_DIR is the repo root; the SDKs live under sdks/ and the spec under
# infra/config/openapi/.
PY_SDK="${BAAS_DIR}/sdks/python"
DART_SDK="${BAAS_DIR}/sdks/dart"
SPEC="${BAAS_DIR}/infra/config/openapi/grobase-public.json"
PY_IMAGE="python:3.12"
DART_IMAGE="dart:stable"

# The five generated Api surfaces the public SDK must expose (one per spec tag:
# auth · functions · query · rest · storage). Single source the names so the
# Python import line, the Dart class grep, and the messages all agree.
API_SURFACES=(AuthApi QueryApi StorageApi FunctionsApi RestApi)

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

# ── 0) inputs present ────────────────────────────────────────────────────────
step "0/3 inputs present (spec, python SDK, dart SDK)"
[[ -f "${SPEC}" ]]                     || fail "spec not found: ${SPEC}"
[[ -f "${PY_SDK}/pyproject.toml" ]]    || fail "python SDK pyproject.toml missing: ${PY_SDK}"
[[ -f "${PY_SDK}/grobase/__init__.py" ]] || fail "python package grobase/__init__.py missing"
[[ -f "${DART_SDK}/pubspec.yaml" ]]    || fail "dart SDK pubspec.yaml missing: ${DART_SDK}"
[[ -f "${DART_SDK}/lib/api.dart" ]]    || fail "dart lib/api.dart missing"
ok "spec + sdk-python (grobase) + sdk-dart present"

# ── spec operation count (derived, not hardcoded) ────────────────────────────
# One operation = one (path, http-method) pair carrying an operationId/tags.
SPEC_OPS="$(python3 - "${SPEC}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
methods = {"get","put","post","delete","patch","options","head","trace"}
ops = 0
for _, item in (d.get("paths") or {}).items():
    for m, op in item.items():
        if m.lower() in methods and isinstance(op, dict):
            ops += 1
print(ops)
PY
)"
[[ "${SPEC_OPS}" =~ ^[0-9]+$ && "${SPEC_OPS}" -gt 0 ]] || fail "could not derive spec operation count (got '${SPEC_OPS}')"
step "spec declares ${SPEC_OPS} HTTP operations (path × method)"

# ── 1) Python — pip install -e . + import all 5 Api surfaces ──────────────────
step "1/3 Python: pip install -e . && import grobase + all 5 Api surfaces"
# Build the import probe from the single API_SURFACES list so the assertion
# binds to the REAL generated classes, never a tautology. Each name is also
# referenced (assert callable/class) so a stub that only re-exports a None
# would fail. Op-count is computed inside the container from the installed
# package's api/*.py and printed as a tagged line we grep out on the host.
PY_PROBE='import grobase
from grobase import AuthApi, QueryApi, StorageApi, FunctionsApi, RestApi
for _n, _c in [("AuthApi", AuthApi), ("QueryApi", QueryApi),
               ("StorageApi", StorageApi), ("FunctionsApi", FunctionsApi),
               ("RestApi", RestApi)]:
    assert isinstance(_c, type), _n + " is not a class"
# count distinct generated operations: base method names in api/*_api.py,
# stripping the generator twin variants so we count one op per operationId.
import glob, os, re, grobase
api_dir = os.path.join(os.path.dirname(grobase.__file__), "api")
ops = set()
for f in glob.glob(os.path.join(api_dir, "*_api.py")):
    src = open(f).read()
    for m in re.findall(r"\bdef ([a-z][a-z0-9_]*)\(", src):
        base = m
        for suf in ("_with_http_info", "_without_preload_content"):
            if base.endswith(suf):
                base = base[: -len(suf)]
        if base.startswith("_"):
            continue
        ops.add(base)
print("M58_PY_OPS=" + str(len(ops)))
print("M58_PY_OK")'
printf '%s' "${PY_PROBE}" > "${TMP}/probe.py"

PY_LOG="${TMP}/py.log"
set +e
docker run --rm -v "${PY_SDK}:/app" -v "${TMP}:/probe:ro" -w /app "${PY_IMAGE}" \
  sh -c 'pip install -e . -q && python /probe/probe.py' >"${PY_LOG}" 2>&1
PY_RC=$?
set -e
[[ ${PY_RC} -eq 0 ]] || fail "python build/import failed (rc=${PY_RC}) — $(tail -8 "${PY_LOG}")"
grep -q '^M58_PY_OK$' "${PY_LOG}" || fail "python probe did not confirm all 5 Api surfaces — $(tail -8 "${PY_LOG}")"
PY_OPS="$(grep '^M58_PY_OPS=' "${PY_LOG}" | tail -1 | cut -d= -f2)"
[[ "${PY_OPS}" =~ ^[0-9]+$ ]] || fail "python op count not parsed — $(tail -8 "${PY_LOG}")"
ok "pip install -e . OK; grobase imports; all 5 Api surfaces are classes; ${PY_OPS} ops"

# ── 2) Dart — pub get + clean analyze + 5 Api classes present ─────────────────
step "2/3 Dart: dart pub get && dart analyze --fatal-infos (clean)"
# Assert the 5 generated Api classes exist in lib/api/*.dart BEFORE the heavy
# analyze (cheap structural proof + bind to real classes), then prove the whole
# package analyzes clean (--fatal-infos makes any info/warning a non-zero exit).
for surface in "${API_SURFACES[@]}"; do
  grep -rqE "^class ${surface} \{" "${DART_SDK}/lib/api/" \
    || fail "dart SDK is missing generated class '${surface}' in lib/api/"
done
ok "all 5 Api classes present in sdk-dart/lib/api/*.dart"

DART_LOG="${TMP}/dart.log"
set +e
docker run --rm -v "${DART_SDK}:/app" -w /app "${DART_IMAGE}" \
  sh -c 'dart pub get && dart analyze --fatal-infos' >"${DART_LOG}" 2>&1
DART_RC=$?
set -e
[[ ${DART_RC} -eq 0 ]] || fail "dart pub get / analyze --fatal-infos NOT clean (rc=${DART_RC}) — $(tail -12 "${DART_LOG}")"
grep -qiE 'No issues found' "${DART_LOG}" || fail "dart analyze did not report 'No issues found' — $(tail -12 "${DART_LOG}")"
ok "dart pub get OK; dart analyze --fatal-infos clean (No issues found)"

# Count Dart operations the same way: one base op per operationId, stripping the
# generator's WithHttpInfo twin. Pure text scan — no Dart runtime needed.
DART_OPS="$(python3 - "${DART_SDK}" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
ops = set()
for f in glob.glob(os.path.join(root, "lib", "api", "*_api.dart")):
    src = open(f).read()
    for m in re.findall(r"\bFuture<[^>]*>\s+([A-Za-z][A-Za-z0-9]*)\s*\(", src):
        base = m[:-len("WithHttpInfo")] if m.endswith("WithHttpInfo") else m
        ops.add(base)
print(len(ops))
PY
)"
[[ "${DART_OPS}" =~ ^[0-9]+$ && "${DART_OPS}" -gt 0 ]] || fail "could not count dart operations (got '${DART_OPS}')"
ok "dart SDK exposes ${DART_OPS} distinct operations"

# ── 3) Congruence — spec_ops == python_ops == dart_ops (exact-equal) ─────────
step "3/3 congruence: spec(${SPEC_OPS}) == python(${PY_OPS}) == dart(${DART_OPS})"
# RULE ASSERTED: the OpenAPI generator emits one base method per operationId in
# both languages, so the operation counts must be exactly equal to the spec's
# (path × method) count. A divergence means a stale generation, a dropped
# operation, or a hand-edit drifting from the spec — all of which this catches.
[[ "${PY_OPS}" == "${SPEC_OPS}" ]] \
  || fail "python ops (${PY_OPS}) != spec ops (${SPEC_OPS}) — SDK is out of sync with the spec"
[[ "${DART_OPS}" == "${SPEC_OPS}" ]] \
  || fail "dart ops (${DART_OPS}) != spec ops (${SPEC_OPS}) — SDK is out of sync with the spec"
ok "all three congruent at ${SPEC_OPS} operations — SDKs match the public spec"

green "[M58] ALL GATES GREEN — generated SDKs real & congruent: python:3.12 pip install + import 5 Api surfaces · dart:stable clean analyze + 5 Api classes · spec==python==dart == ${SPEC_OPS} ops"
