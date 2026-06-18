import * as fs from 'node:fs/promises';
import * as path from 'node:path';

interface JestResult {
  numPassedTests: number;
  numFailedTests: number;
  numTotalTests: number;
}

interface CustomRawResult {
  summary?: {
    assertionsPassed?: number;
    assertionsFailed?: number;
    assertionsTotal?: number;
  };
}

interface DashboardTestSuite {
  name: string;
  totalPassed?: number;
  totalFailed?: number;
  tests?: Array<{
    status?: string;
    output?: string;
  }>;
}

interface TestSummaryRow {
  name: string;
  passed: number;
  failed: number;
  total: number;
}

interface TestSummary {
  rows: TestSummaryRow[];
  totalPassed: number;
  totalFailed: number;
  totalTests: number;
}

async function readJson<T>(fileName: string): Promise<T | null> {
  try {
    const filePath = path.join(process.cwd(), fileName);
    const content = await fs.readFile(filePath, 'utf-8');
    return JSON.parse(content) as T;
  } catch {
    return null;
  }
}

function jestRow(name: string, result: JestResult | null): TestSummaryRow {
  return {
    name,
    passed: result?.numPassedTests ?? 0,
    failed: result?.numFailedTests ?? 0,
    total: result?.numTotalTests ?? 0,
  };
}

function customRow(result: CustomRawResult | null): TestSummaryRow {
  return {
    name: 'Custom validation',
    passed: result?.summary?.assertionsPassed ?? 0,
    failed: result?.summary?.assertionsFailed ?? 0,
    total: result?.summary?.assertionsTotal ?? 0,
  };
}

function parseCountFromOutput(output?: string): number {
  const match = output?.match(/All (\d+) /);
  return match ? Number(match[1]) : 0;
}

function customDashboardRow(result: DashboardTestSuite[] | null): TestSummaryRow {
  const tests = result?.flatMap((suite) => suite.tests ?? []) ?? [];
  const inferredTotal = tests.reduce(
    (total, test) => total + parseCountFromOutput(test.output),
    0,
  );
  const total = inferredTotal || tests.length;
  const failed = tests.filter((test) => test.status === 'failed').length;

  return {
    name: 'Custom validation',
    passed: total - failed,
    failed,
    total,
  };
}

function postmanRow(result: DashboardTestSuite[] | null): TestSummaryRow {
  const passed =
    result?.reduce((total, suite) => total + (suite.totalPassed ?? 0), 0) ?? 0;
  const failed =
    result?.reduce((total, suite) => total + (suite.totalFailed ?? 0), 0) ?? 0;
  const tests = result?.reduce(
    (total, suite) => total + (suite.tests?.length ?? 0),
    0,
  );
  const total = tests ?? passed + failed;

  return {
    name: 'Postman API',
    passed,
    failed,
    total,
  };
}

function summarize(rows: TestSummaryRow[]): TestSummary {
  const totals = rows.reduce(
    (acc, row) => ({
      totalPassed: acc.totalPassed + row.passed,
      totalFailed: acc.totalFailed + row.failed,
      totalTests: acc.totalTests + row.total,
    }),
    { totalPassed: 0, totalFailed: 0, totalTests: 0 },
  );

  return { rows, ...totals };
}

function formatMarkdown(summary: TestSummary): string {
  const tableRows = summary.rows
    .map(
      (row) => `| ${row.name} | ${row.passed} | ${row.failed} | ${row.total} |`,
    )
    .join('\n');

  return [
    '## Test Summary',
    '',
    '| Suite | Passed | Failed | Total |',
    '| --- | ---: | ---: | ---: |',
    tableRows,
    `| **Total** | **${summary.totalPassed}** | **${summary.totalFailed}** | **${summary.totalTests}** |`,
    '',
  ].join('\n');
}

async function writeJson(fileName: string, data: unknown): Promise<void> {
  const filePath = path.join(process.cwd(), fileName);
  await fs.writeFile(filePath, `${JSON.stringify(data, null, 2)}\n`, 'utf-8');
}

async function run(): Promise<void> {
  const [unit, e2e, customRaw, customDashboard, postman] = await Promise.all([
    readJson<JestResult>('test-results-unit.json'),
    readJson<JestResult>('test-results-e2e.json'),
    readJson<CustomRawResult>('test-results-custom-raw.json'),
    readJson<DashboardTestSuite[]>('test-results-custom.json'),
    readJson<DashboardTestSuite[]>('test-results-postman.json'),
  ]);

  const custom = customRaw?.summary
    ? customRow(customRaw)
    : customDashboardRow(customDashboard);
  const rows = [
    jestRow('Jest unit', unit),
    jestRow('Jest e2e', e2e),
    custom,
    postmanRow(postman),
  ];
  const summary = summarize(rows);
  const markdown = formatMarkdown(summary);

  console.log(markdown);
  await writeJson('test-results-summary.json', summary);

  const stepSummaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (stepSummaryPath) {
    await fs.appendFile(stepSummaryPath, markdown, 'utf-8');
  }

  const minimumTotal = Number(process.env.MIN_TOTAL_TESTS ?? 0);
  if (minimumTotal > 0 && summary.totalTests < minimumTotal) {
    console.error(
      `Expected at least ${minimumTotal} tests, but only ${summary.totalTests} were reported.`,
    );
    process.exitCode = 1;
  }

  if (summary.totalFailed > 0) {
    console.error(`${summary.totalFailed} tests failed.`);
    process.exitCode = 1;
  }
}

void run().catch((error: unknown) => {
  console.error(error instanceof Error ? error.stack : String(error));
  process.exitCode = 1;
});
