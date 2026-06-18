#!/usr/bin/env bash
# **************************************************************************** #
#   codegen-polyglot.sh — regenerate the Python/Dart/Swift/Kotlin SDKs        #
# **************************************************************************** #
#
# A4: polyglot SDKs generated from the canonical OpenAPI 3.1 spec
#   infra/config/openapi/grobase-public.json
# into committed, regenerable packages:
#   apps/baas/sdks/python   (urllib3-based)
#   apps/baas/sdks/dart     (http-based)
#   apps/baas/sdks/swift    (urlsession + async/await)
#   apps/baas/sdks/kotlin   (jvm + gradle)
#
# The hand-written TypeScript SDK (apps/baas/sdks/js) is the reference client and is
# NOT generated. Docker-first: openapi-generator runs in a container, so its
# layers land on the docker data-root (/mnt/storage), never the system disk;
# only the generated SOURCE is written into the repo.
#
# Usage:  bash apps/baas/sdks/js/scripts/codegen-polyglot.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # apps/baas/sdks/js/scripts
BAAS_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"           # apps/baas
SPEC="infra/config/openapi/grobase-public.json"
IMG="${OPENAPI_GENERATOR_IMAGE:-openapitools/openapi-generator-cli:latest}"
VERSION="${SDK_VERSION:-0.2.0}"

[ -f "${BAAS_DIR}/${SPEC}" ] || {
  echo "spec not found: ${BAAS_DIR}/${SPEC}" >&2
  exit 1
}

gen() { # $1 generator  $2 out-dir  $3 additional-properties
  # --user: write generated source as the host user (the image runs as root by
  # default, which would leave root-owned files in the repo that can't be cleaned
  # without sudo). Regenerating over a pre-existing dir: remove/mv it first.
  docker run --rm --user "$(id -u):$(id -g)" -v "${BAAS_DIR}:/work" "${IMG}" generate \
    -i "/work/${SPEC}" -g "$1" -o "/work/$2" \
    --additional-properties="$3"
}

# patch_swift_linux_portability — make the swift5-generated URLSession helper
# compile AND link on Linux (Docker-first CI), not just on Apple. The swift5
# generator emits three Apple-only portability artifacts in
# URLSessionImplementations.swift that break `swift build` on Linux:
#   (1) `#if !os(macOS)` guards `import MobileCoreServices` — but `!os(macOS)`
#       is TRUE on Linux, so it imports a framework Linux lacks. The correct
#       guard is `canImport(MobileCoreServices)` (false on Linux → skipped).
#   (2) the legacy pre-macOS-11 MIME branch calls UTTypeCreate*/kUTTag* C
#       symbols that only exist inside MobileCoreServices — guard it the same
#       way, falling back to "application/octet-stream" on Linux.
#   (3) URLSession/URLRequest/URLCredential live in FoundationNetworking on
#       Linux (not core Foundation) — add a `canImport(FoundationNetworking)`
#       import so the networking types resolve and the package links.
# Applied as a deterministic, idempotent post-generation patch so it survives
# regeneration (the file is committed, not gitignored). No-op if already patched.
patch_swift_linux_portability() {
  f="${BAAS_DIR}/sdks/swift/URLSessionImplementations.swift"
  [ -f "${f}" ] || {
    echo "[codegen-polyglot] WARN: ${f} absent — skip swift Linux patch" >&2
    return 0
  }
  if grep -q 'canImport(FoundationNetworking)' "${f}"; then
    echo "[codegen-polyglot] swift Linux portability patch already present — skip"
    return 0
  fi
  perl -0pi -e '
    s/#if !os\(macOS\)\n(import MobileCoreServices\n#endif\n)/#if canImport(MobileCoreServices)\n$1#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n/;
    s/(\} else \{\n)(\s*if let uti = UTTypeCreatePreferredIdentifierForTag.*?return "application\/octet-stream"\n)(\s*\}\n)/$1#if canImport(MobileCoreServices)\n$2#else\n            return "application\/octet-stream"\n#endif\n$3/s;
  ' "${f}"
  grep -q 'canImport(FoundationNetworking)' "${f}" ||
    { echo "[codegen-polyglot] ERROR: swift Linux patch did not apply to ${f}" >&2; return 1; }
  echo "[codegen-polyglot] patched swift URLSessionImplementations.swift for Linux build (MobileCoreServices/FoundationNetworking guards)"
}

echo "[codegen-polyglot] Python -> sdks/python"
gen python sdks/python "packageName=grobase,projectName=grobase-sdk,packageVersion=${VERSION},library=urllib3"

echo "[codegen-polyglot] Dart -> sdks/dart"
gen dart sdks/dart "pubName=grobase,pubVersion=${VERSION}"

# A4-swift: Swift client (urlsession + async/await), package "Grobase". SPM
# layout with path:"." so all sources live at the package root; the m62 gate
# builds it in swift:5.9. patch_swift_linux_portability fixes the swift5
# generator's Apple-only artifacts (MobileCoreServices import + FoundationNetworking)
# so `swift build` LINKS on Linux — no parse-fallback needed.
echo "[codegen-polyglot] Swift -> sdks/swift"
gen swift5 sdks/swift "projectName=Grobase,library=urlsession,responseAs=AsyncAwait,useSPMFileStructure=true,swiftPackagePath=."
patch_swift_linux_portability

# A4-kotlin: Kotlin client (jvm + gradle), package "grobase", artifactId
# grobase-sdk (group com.grobase). The m63 gate builds it with `gradle build` in
# gradle:8-jdk17 (kotlinc -parse fallback for air-gapped CI). NOTE: the committed
# sdks/kotlin/ was first generated at version 1.1.0; this recipe standardizes the
# whole suite on ${VERSION}, so a regen restamps it to match python/dart/swift.
echo "[codegen-polyglot] Kotlin -> sdks/kotlin"
gen kotlin sdks/kotlin "packageName=grobase,groupId=com.grobase,artifactId=grobase-sdk,artifactVersion=${VERSION}"

echo "[codegen-polyglot] done — regenerated sdks/{python,dart,swift,kotlin} from ${SPEC}"
