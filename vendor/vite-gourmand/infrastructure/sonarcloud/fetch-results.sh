#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR/results}"
PROJECT_KEY="${SONAR_PROJECT_KEY:-LESdylan_vite-gourmand}"
SONAR_HOST_URL="${SONAR_HOST_URL:-https://sonarcloud.io}"
PAGE_SIZE="${SONAR_PAGE_SIZE:-500}"

load_sonar_token() {
  if [[ -n "${SONAR_TOKEN:-}" ]]; then
    printf '%s' "$SONAR_TOKEN"
    return
  fi

  local env_file="$REPO_ROOT/.env.production"
  if [[ -f "$env_file" ]]; then
    awk -F= '$1 == "SONAR_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "$env_file" \
      | tr -d '\r' \
      | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
  fi
}

SONAR_TOKEN_VALUE="$(load_sonar_token)"
if [[ -z "$SONAR_TOKEN_VALUE" ]]; then
  echo "SONAR_TOKEN is required. Export it or define it in .env.production." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

api_get() {
  local path="$1"
  local output="$2"
  curl --fail --silent --show-error \
    --user "$SONAR_TOKEN_VALUE:" \
    "$SONAR_HOST_URL$path" \
    --output "$output"
}

encoded_project_key="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$PROJECT_KEY")"

api_get "/api/qualitygates/project_status?projectKey=$encoded_project_key" "$OUTPUT_DIR/quality-gate.json"
api_get "/api/measures/component?component=$encoded_project_key&metricKeys=bugs,vulnerabilities,security_hotspots,code_smells,reliability_rating,security_rating,sqale_rating,coverage,duplicated_lines_density,ncloc" "$OUTPUT_DIR/measures.json"

page=1
total=0
while :; do
  page_file="$TMP_DIR/issues-$page.json"
  api_get "/api/issues/search?componentKeys=$encoded_project_key&resolved=false&ps=$PAGE_SIZE&p=$page&facets=severities,types,rules" "$page_file"

  total="$(node -e 'const fs = require("fs"); const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(data.total || 0);' "$page_file")"
  fetched=$((page * PAGE_SIZE))
  if (( fetched >= total )); then
    break
  fi
  page=$((page + 1))
done

node - "$TMP_DIR" "$OUTPUT_DIR/issues.json" "$PROJECT_KEY" <<'NODE'
const fs = require('fs');
const path = require('path');

const inputDir = process.argv[2];
const outputFile = process.argv[3];
const projectKey = process.argv[4];
const files = fs
  .readdirSync(inputDir)
  .filter((file) => file.startsWith('issues-') && file.endsWith('.json'))
  .sort((a, b) => Number(a.match(/issues-(\d+)\.json/)[1]) - Number(b.match(/issues-(\d+)\.json/)[1]));

const pages = files.map((file) => JSON.parse(fs.readFileSync(path.join(inputDir, file), 'utf8')));
const firstPage = pages[0] || { total: 0, facets: [] };
const issues = pages.flatMap((page) => page.issues || []);

fs.writeFileSync(
  outputFile,
  `${JSON.stringify(
    {
      projectKey,
      fetchedAt: new Date().toISOString(),
      total: firstPage.total || issues.length,
      pageCount: pages.length,
      issues,
      facets: firstPage.facets || [],
    },
    null,
    2,
  )}\n`,
);
NODE

node - "$OUTPUT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');

const outputDir = process.argv[2];
const issues = JSON.parse(fs.readFileSync(path.join(outputDir, 'issues.json'), 'utf8'));
const measures = JSON.parse(fs.readFileSync(path.join(outputDir, 'measures.json'), 'utf8'));
const qualityGate = JSON.parse(fs.readFileSync(path.join(outputDir, 'quality-gate.json'), 'utf8'));

const byType = issues.issues.reduce((acc, issue) => {
  acc[issue.type] = (acc[issue.type] || 0) + 1;
  return acc;
}, {});

const bySeverity = issues.issues.reduce((acc, issue) => {
  acc[issue.severity] = (acc[issue.severity] || 0) + 1;
  return acc;
}, {});

fs.writeFileSync(
  path.join(outputDir, 'summary.json'),
  `${JSON.stringify(
    {
      fetchedAt: issues.fetchedAt,
      projectKey: issues.projectKey,
      qualityGate: qualityGate.projectStatus?.status || 'UNKNOWN',
      unresolvedIssues: issues.total,
      byType,
      bySeverity,
      measures: measures.component?.measures || [],
    },
    null,
    2,
  )}\n`,
);
NODE

echo "Wrote SonarQube Cloud JSON results to $OUTPUT_DIR" >&2