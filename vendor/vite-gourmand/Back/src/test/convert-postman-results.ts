import * as fs from 'node:fs/promises';
import * as path from 'node:path';

interface NewmanAssertion {
  assertion?: string;
  error?: {
    message?: string;
    stack?: string;
  };
}

interface NewmanExecution {
  item?: {
    name?: string;
  };
  response?: {
    responseTime?: number;
  };
  assertions?: NewmanAssertion[];
}

interface NewmanRawResult {
  collection?: {
    info?: {
      name?: string;
    };
  };
  run?: {
    executions?: NewmanExecution[];
  };
}

interface DashboardTestResult {
  id: string;
  name: string;
  status: 'passed' | 'failed';
  duration: number;
  error?: string;
}

interface DashboardTestSuite {
  name: string;
  type: 'postman';
  tests: DashboardTestResult[];
  totalPassed: number;
  totalFailed: number;
  totalDuration: number;
}

const DEFAULT_INPUT = 'test-results-postman-raw.json';
const DEFAULT_OUTPUT = 'test-results-postman.json';

async function readJson<T>(fileName: string): Promise<T> {
  const filePath = path.join(process.cwd(), fileName);
  const content = await fs.readFile(filePath, 'utf-8');
  return JSON.parse(content) as T;
}

async function writeJson(fileName: string, data: unknown): Promise<void> {
  const filePath = path.join(process.cwd(), fileName);
  await fs.writeFile(filePath, `${JSON.stringify(data, null, 2)}\n`, 'utf-8');
}

function assertionName(
  execution: NewmanExecution,
  assertion: NewmanAssertion,
): string {
  const itemName = execution.item?.name ?? 'Postman request';
  return assertion.assertion ? `${itemName}: ${assertion.assertion}` : itemName;
}

function toDashboardResults(rawResult: NewmanRawResult): DashboardTestSuite[] {
  const tests: DashboardTestResult[] = [];
  let totalDuration = 0;

  for (const execution of rawResult.run?.executions ?? []) {
    const assertions = execution.assertions ?? [];
    const duration = execution.response?.responseTime ?? 0;
    totalDuration += duration;

    if (assertions.length === 0) {
      tests.push({
        id: `postman-${tests.length}`,
        name: execution.item?.name ?? 'Postman request without assertions',
        status: 'failed',
        duration,
        error: 'Request executed without Postman assertions',
      });
      continue;
    }

    for (const assertion of assertions) {
      tests.push({
        id: `postman-${tests.length}`,
        name: assertionName(execution, assertion),
        status: assertion.error ? 'failed' : 'passed',
        duration,
        error: assertion.error?.message ?? assertion.error?.stack,
      });
    }
  }

  const totalFailed = tests.filter((test) => test.status === 'failed').length;
  const dashboardReport: DashboardTestSuite[] = [
    {
      name: rawResult.collection?.info?.name ?? 'Postman API tests',
      type: 'postman',
      tests,
      totalPassed: tests.length - totalFailed,
      totalFailed,
      totalDuration,
    },
  ];

  return dashboardReport;
}

async function run(): Promise<void> {
  const inputFile = process.argv[2] ?? DEFAULT_INPUT;
  const outputFile = process.argv[3] ?? DEFAULT_OUTPUT;
  const rawResult = await readJson<NewmanRawResult>(inputFile);
  const dashboardReport = toDashboardResults(rawResult);

  await writeJson(outputFile, dashboardReport);

  const totals = dashboardReport[0];
  console.log(
    `Postman Test Cases: ${totals.totalPassed} passed, ${totals.totalFailed} failed, ${totals.tests.length} total`,
  );

  if (totals.totalFailed > 0) {
    process.exitCode = 1;
  }
}

void run().catch((error: unknown) => {
  console.error(error instanceof Error ? error.stack : String(error));
  process.exitCode = 1;
});