#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

const outputDir = process.argv[2] || path.join(__dirname, 'results');
const summaryPath = path.join(outputDir, 'summary.json');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function measureValue(summary, metric) {
  const measure = summary.measures?.find((item) => item.metric === metric);
  return measure?.value ?? '0';
}

if (!fs.existsSync(summaryPath)) {
  console.error(`SonarCloud summary not found: ${summaryPath}`);
  process.exit(1);
}

const summary = readJson(summaryPath);
const qualityGate = summary.qualityGate || 'UNKNOWN';
const unresolvedIssues = Number(summary.unresolvedIssues || 0);

const markdown = [
  '## SonarCloud Summary',
  '',
  '| Metric | Value |',
  '| --- | ---: |',
  `| Quality gate | ${qualityGate} |`,
  `| Unresolved issues | ${unresolvedIssues} |`,
  `| Bugs | ${measureValue(summary, 'bugs')} |`,
  `| Vulnerabilities | ${measureValue(summary, 'vulnerabilities')} |`,
  `| Security hotspots | ${measureValue(summary, 'security_hotspots')} |`,
  `| Code smells | ${measureValue(summary, 'code_smells')} |`,
  `| Coverage | ${measureValue(summary, 'coverage')}% |`,
  `| Duplicated lines | ${measureValue(summary, 'duplicated_lines_density')}% |`,
  '',
].join('\n');

console.log(markdown);

if (process.env.GITHUB_STEP_SUMMARY) {
  fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown, 'utf8');
}

if (qualityGate !== 'OK' || unresolvedIssues > 0) {
  process.exitCode = 1;
}