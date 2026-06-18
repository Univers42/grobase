import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import { DbMailConnectionTest } from './unit_tests/db-mail-connection.test';
import { EmailValidationTest } from './unit_tests/email-validation.test';
import { FirstTimeRegistrationTest } from './unit_tests/first-time-registration.test';
import { PasswordStrengthTest } from './unit_tests/password-strength.test';
import { QuickConnectionTest } from './unit_tests/quick-connection.test';
import { ResetPasswordTest } from './unit_tests/reset-password.test';
import { VerifyCreditCardTest } from './unit_tests/verify-credit-card.test';
import type { TestResult as CustomTestResult } from './unit_tests/base.test';

type CustomTestConstructor = new () => {
  name: string;
  description: string;
  run: () => Promise<CustomTestResult>;
};

interface TestDefinition {
  file: string;
  TestClass: CustomTestConstructor;
}

interface DashboardTestResult {
  id: string;
  name: string;
  status: 'passed' | 'failed';
  duration: number;
  error?: string;
  output?: string;
}

interface DashboardTestSuite {
  name: string;
  type: 'custom';
  tests: DashboardTestResult[];
  totalPassed: number;
  totalFailed: number;
  totalDuration: number;
}

interface RawCustomTestResult extends CustomTestResult {
  file: string;
  description: string;
  assertionsPassed: number;
  assertionsFailed: number;
  assertionsTotal: number;
}

interface RawCustomTestReport {
  summary: {
    suitesPassed: number;
    suitesFailed: number;
    suitesTotal: number;
    assertionsPassed: number;
    assertionsFailed: number;
    assertionsTotal: number;
    duration: number;
  };
  results: RawCustomTestResult[];
}

const tests: TestDefinition[] = [
  { file: 'email-validation.test.ts', TestClass: EmailValidationTest },
  { file: 'verify-credit-card.test.ts', TestClass: VerifyCreditCardTest },
  { file: 'password-strength.test.ts', TestClass: PasswordStrengthTest },
  {
    file: 'first-time-registration.test.ts',
    TestClass: FirstTimeRegistrationTest,
  },
  { file: 'reset-password.test.ts', TestClass: ResetPasswordTest },
  { file: 'quick-connection.test.ts', TestClass: QuickConnectionTest },
  { file: 'db-mail-connection.test.ts', TestClass: DbMailConnectionTest },
];

function getNumericDetail(
  details: Record<string, unknown> | undefined,
  key: string,
): number {
  const value = details?.[key];
  return typeof value === 'number' ? value : 0;
}

function getAssertionCounts(result: CustomTestResult): {
  passed: number;
  failed: number;
} {
  const passed = getNumericDetail(result.details, 'passed');
  const failed = getNumericDetail(result.details, 'failed');

  if (passed + failed > 0) {
    return { passed, failed };
  }

  return result.passed ? { passed: 1, failed: 0 } : { passed: 0, failed: 1 };
}

async function writeJson(fileName: string, data: unknown): Promise<void> {
  const filePath = path.join(process.cwd(), fileName);
  await fs.writeFile(filePath, `${JSON.stringify(data, null, 2)}\n`, 'utf-8');
}

async function run(): Promise<void> {
  const startedAt = Date.now();
  const dashboardResults: DashboardTestResult[] = [];
  const rawResults: RawCustomTestResult[] = [];
  let suitesPassed = 0;
  let suitesFailed = 0;
  let assertionsPassed = 0;
  let assertionsFailed = 0;
  let totalDuration = 0;

  for (const testDefinition of tests) {
    const test = new testDefinition.TestClass();
    const testStartedAt = Date.now();

    try {
      const result = await test.run();
      const duration = result.duration || Date.now() - testStartedAt;
      const assertionCounts = getAssertionCounts(result);

      totalDuration += duration;
      assertionsPassed += assertionCounts.passed;
      assertionsFailed += assertionCounts.failed;

      if (result.passed) {
        suitesPassed += 1;
        console.log(`PASS ${testDefinition.file} - ${result.message}`);
      } else {
        suitesFailed += 1;
        console.error(`FAIL ${testDefinition.file} - ${result.message}`);
        for (const error of result.errors ?? []) {
          console.error(`  - ${error}`);
        }
      }

      dashboardResults.push({
        id: `custom-${dashboardResults.length}`,
        name: result.name,
        status: result.passed ? 'passed' : 'failed',
        duration,
        error: result.errors?.join('\n') || undefined,
        output: result.message,
      });

      rawResults.push({
        ...result,
        file: testDefinition.file,
        description: test.description,
        duration,
        assertionsPassed: assertionCounts.passed,
        assertionsFailed: assertionCounts.failed,
        assertionsTotal: assertionCounts.passed + assertionCounts.failed,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const duration = Date.now() - testStartedAt;

      suitesFailed += 1;
      assertionsFailed += 1;
      totalDuration += duration;
      console.error(`FAIL ${testDefinition.file} - ${message}`);

      dashboardResults.push({
        id: `custom-${dashboardResults.length}`,
        name: test.name,
        status: 'failed',
        duration,
        error: message,
      });

      rawResults.push({
        name: test.name,
        passed: false,
        message,
        duration,
        errors: [message],
        file: testDefinition.file,
        description: test.description,
        assertionsPassed: 0,
        assertionsFailed: 1,
        assertionsTotal: 1,
      });
    }
  }

  const dashboardReport: DashboardTestSuite[] = [
    {
      name: 'custom-unit-tests',
      type: 'custom',
      tests: dashboardResults,
      totalPassed: suitesPassed,
      totalFailed: suitesFailed,
      totalDuration,
    },
  ];

  const rawReport: RawCustomTestReport = {
    summary: {
      suitesPassed,
      suitesFailed,
      suitesTotal: suitesPassed + suitesFailed,
      assertionsPassed,
      assertionsFailed,
      assertionsTotal: assertionsPassed + assertionsFailed,
      duration: Date.now() - startedAt,
    },
    results: rawResults,
  };

  await writeJson('test-results-custom.json', dashboardReport);
  await writeJson('test-results-custom-raw.json', rawReport);

  console.log(
    `Custom Test Suites: ${suitesPassed} passed, ${suitesFailed} failed, ${suitesPassed + suitesFailed} total`,
  );
  console.log(
    `Custom Test Cases: ${assertionsPassed} passed, ${assertionsFailed} failed, ${assertionsPassed + assertionsFailed} total`,
  );

  if (suitesFailed > 0 || assertionsFailed > 0) {
    process.exitCode = 1;
  }
}

void run().catch((error: unknown) => {
  console.error(error instanceof Error ? error.stack : String(error));
  process.exitCode = 1;
});
