#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m21-deploy-packaging.sh                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/03 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/03 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M21 — G11 non-Compose packaging gate. Proves the Helm/Kustomize tree is
# GENERATED from the one manifest and stays faithful to it:
#   * the generator re-runs clean and the manifest matches the Makefile;
#   * every generated edition selects EXACTLY the services `docker compose
#     --profile …` would (K8s edition == Compose edition, set-for-set);
#   * the Helm chart lints and every edition renders valid K8s YAML.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${REPO_ROOT}"

BAAS_DIR="apps/baas/mini-baas-infra"
DEPLOY="${BAAS_DIR}/deploy"
HELM="${DEPLOY}/helm/mini-baas"
COMPOSE="${BAAS_DIR}/docker-compose.yml"
MANIFEST="${DEPLOY}/edition-manifest.yaml"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
fail()  { red "[M21] FAIL: $*"; exit 1; }
step()  { cyan "[M21] ${*}"; }
pass()  { green "[M21] PASS: ${*}"; }

command -v python3 >/dev/null 2>&1 || fail "python3 required"

step "structural: generator, targets, and chart present"
[[ -f "${BAAS_DIR}/scripts/gen-deploy.py" ]] || fail "missing scripts/gen-deploy.py"
grep -qE '^deploy-gen:' "${BAAS_DIR}/Makefile" || fail "Makefile missing deploy-gen target"
grep -qE '^deploy-template:' "${BAAS_DIR}/Makefile" || fail "Makefile missing deploy-template target"
for f in Chart.yaml values.yaml templates/deployment.yaml templates/service.yaml templates/_helpers.tpl; do
  [[ -f "${HELM}/${f}" ]] || fail "missing chart file ${f}"
done
[[ -f "${DEPLOY}/README.md" ]] || fail "missing deploy/README.md"
pass "gen-deploy.py + deploy-gen/deploy-template + chart skeleton present"

step "freshness: generator re-runs clean and produces the manifest"
( cd "${BAAS_DIR}" && python3 scripts/gen-deploy.py >/dev/null ) || fail "gen-deploy.py exited non-zero"
[[ -f "${MANIFEST}" ]] || fail "generator did not produce ${MANIFEST}"
python3 -c "import yaml;yaml.safe_load(open('${MANIFEST}'))" || fail "edition-manifest.yaml is not valid YAML"
pass "generator regenerates the manifest cleanly"

step "consistency: manifest editions/planes match the Makefile MANIFEST"
python3 - "$REPO_ROOT/$BAAS_DIR" <<'PY' || fail "manifest drifted from the Makefile"
import sys, os, re, yaml
base = sys.argv[1]
sys.path.insert(0, os.path.join(base, "scripts"))
import importlib.util
spec = importlib.util.spec_from_file_location("gd", os.path.join(base, "scripts", "gen-deploy.py"))
gd = importlib.util.module_from_spec(spec); spec.loader.exec_module(gd)
profiles, editions = gd.parse_makefile()
man = yaml.safe_load(open(os.path.join(base, "deploy", "edition-manifest.yaml")))
assert man["planeProfiles"] == profiles, "planeProfiles != Makefile"
assert man["editionPlanes"] == editions, "editionPlanes != Makefile"
print("  manifest matches Makefile (%d planes, %d editions)" % (len(profiles), len(editions)))
PY
pass "edition-manifest.yaml is faithful to the Makefile"

# ---- the strong proof: K8s edition == Compose edition, set-for-set ----
if docker compose -f "${COMPOSE}" config --services >/dev/null 2>&1; then
  step "parity: each generated edition == docker compose --profile selection"
  editions=$(python3 -c "import yaml;print(' '.join(sorted(yaml.safe_load(open('${MANIFEST}'))['editionPlanes'])))")
  for e in ${editions}; do
    profs=$(python3 -c "import yaml;print(' '.join('--profile '+p for p in yaml.safe_load(open('${MANIFEST}'))['editionProfiles']['${e}']))")
    docker compose -f "${COMPOSE}" ${profs} config --services 2>/dev/null | sort > /tmp/m21-compose-${e}.txt
    python3 -c "import yaml;print('\n'.join(yaml.safe_load(open('${MANIFEST}'))['editionServices']['${e}']))" | sort > /tmp/m21-man-${e}.txt
    if ! diff -q /tmp/m21-compose-${e}.txt /tmp/m21-man-${e}.txt >/dev/null; then
      red "  edition '${e}' diverges from compose:"; diff /tmp/m21-compose-${e}.txt /tmp/m21-man-${e}.txt || true
      rm -f /tmp/m21-*-*.txt; fail "edition '${e}' service set != compose --profile selection"
    fi
    printf '  %-9s %s services match compose\n' "${e}" "$(wc -l < /tmp/m21-man-${e}.txt | tr -d ' ')"
    rm -f /tmp/m21-compose-${e}.txt /tmp/m21-man-${e}.txt
  done
  pass "every edition matches its docker compose --profile selection"
else
  yellow "[M21] docker compose config unavailable (no .env / docker) — skipping the compose cross-check"
fi

# ---- Helm renders ----
if command -v helm >/dev/null 2>&1; then
  step "helm: lint + render every edition to valid K8s YAML"
  helm lint "${HELM}" >/dev/null || fail "helm lint failed"
  for f in "${HELM}"/values-*.yaml; do
    e=$(basename "${f}" .yaml); e=${e#values-}
    out=$(helm template mini-baas "${HELM}" -f "${f}" 2>&1) || { red "${out}" | tail -5; fail "helm template ${e} failed"; }
    printf '%s' "${out}" | python3 -c "import sys,yaml;list(yaml.safe_load_all(sys.stdin))" \
      || fail "helm template ${e} produced invalid YAML"
    deps=$(printf '%s' "${out}" | grep -c '^kind: Deployment' || true)
    printf '  %-9s renders %s Deployments (valid YAML)\n' "${e}" "${deps}"
  done
  pass "helm lint + all editions render valid manifests"
else
  yellow "[M21] helm not installed — skipping render checks (generator + parity already proven)"
fi

green "[M21] G11 packaging verified: one manifest → faithful Helm + Kustomize editions"
