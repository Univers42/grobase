/**
 * Test Runner Service
 * Reads cached test results and can execute tests on demand
 * Parses Jest's native JSON reporter output format
 * Supports: Jest unit tests, E2E tests, Custom unit tests, Postman API tests
 */
import { Injectable, Logger } from '@nestjs/common';
import { spawn } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';

export interface TestResult {
  id: string;
  name: string;
  status: 'passed' | 'failed' | 'skipped' | 'running' | 'idle';
  duration?: number;
  error?: string;
  output?: string;
}

export interface TestSuite {
  name: string;
  type: 'jest' | 'e2e' | 'postman' | 'custom';
  tests: TestResult[];
  totalPassed: number;
  totalFailed: number;
  totalDuration: number;
}

/** Newman/Postman result format */
interface NewmanResult {
  collection: { info: { name: string } };
  run: {
    stats: {
      assertions: { total: number; pending: number; failed: number };
      tests: { total: number; pending: number; failed: number };
    };
    executions: NewmanExecution[];
    timings: { started: number; completed: number };
  };
}

interface NewmanExecution {
  item: { name: string };
  assertions: { assertion: string; error?: { message: string } }[];
  response?: { responseTime: number };
}

/** Custom test result format */
interface CustomTestResult {
  name: string;
  passed: boolean;
  message: string;
  duration: number;
  errors?: string[];
}

export interface RunTestsResponse {
  success: boolean;
  suites: TestSuite[];
  summary: {
    total: number;
    passed: number;
    failed: number;
    duration: number;
  };
  timestamp: string;
  rawOutput?: string;
}

/** Jest's native JSON reporter format */
interface JestResult {
  numFailedTestSuites: number;
  numFailedTests: number;
  numPassedTestSuites: number;
  numPassedTests: number;
  numTotalTestSuites: number;
  numTotalTests: number;
  success: boolean;
  startTime: number;
  testResults: JestTestFile[];
}

interface JestTestFile {
  name: string;
  status: 'passed' | 'failed';
  startTime: number;
  endTime: number;
  message: string;
  assertionResults: JestAssertion[];
}

interface JestAssertion {
  ancestorTitles: string[];
  fullName: string;
  status: 'passed' | 'failed' | 'pending' | 'skipped';
  title: string;
  duration: number;
  failureMessages: string[];
  failureDetails: unknown[];
}

@Injectable()
export class TestRunnerService {
  private readonly logger = new Logger(TestRunnerService.name);
  private isRunning = false;
  private currentTest: string | null = null;
  private cachedResults: RunTestsResponse | null = null;

  /** Get current execution status */
  getStatus(): { running: boolean; currentTest: string | null } {
    return { running: this.isRunning, currentTest: this.currentTest };
  }

  /** Get cached results (or load from file) */
  async getResults(): Promise<RunTestsResponse | null> {
    if (this.cachedResults) return this.cachedResults;

    // Try loading from all test result files
    const [unitData, e2eData, customData, postmanData] = await Promise.all([
      this.readJestResultFile('test-results-unit.json'),
      this.readJestResultFile('test-results-e2e.json'),
      this.readCustomResultFile('test-results-custom.json'),
      this.readPostmanResultFile('test-results-postman.json'),
    ]);

    const suites: TestSuite[] = [];
    if (unitData)
      suites.push(...this.parseJestResult(unitData, 'jest', 'Unit Tests'));
    if (e2eData)
      suites.push(...this.parseJestResult(e2eData, 'e2e', 'E2E Tests'));
    if (customData) suites.push(...customData);
    if (postmanData) suites.push(...postmanData);

    if (suites.length === 0) return null;

    const summary = this.calculateSummary(suites);
    this.cachedResults = {
      success: summary.failed === 0,
      suites,
      summary,
      timestamp: new Date().toISOString(),
    };

    return this.cachedResults;
  }

  /** Run all tests */
  async runAllTests(verbose = true): Promise<RunTestsResponse> {
    if (this.isRunning) {
      throw new Error('Tests are already running');
    }

    this.isRunning = true;
    this.currentTest = 'All Tests';
    const startTime = Date.now();
    const outputs: string[] = [];

    try {
      this.logger.log('🚀 Starting test execution...');

      // Run unit tests with JSON output
      this.currentTest = 'Unit Tests';
      this.logger.log('📦 Running Unit Tests...');
      const unitResult = await this.executeJest('unit', verbose);
      outputs.push(unitResult.output);

      // Run e2e tests with JSON output
      this.currentTest = 'E2E Tests';
      this.logger.log('🌐 Running E2E Tests...');
      const e2eResult = await this.executeJest('e2e', verbose);
      outputs.push(e2eResult.output);

      // Run custom unit tests
      this.currentTest = 'Custom Tests';
      this.logger.log('🔧 Running Custom Unit Tests...');
      const customResult = await this.executeCustomTests(verbose);
      outputs.push(customResult.output);

      // Run Postman tests
      this.currentTest = 'Postman Tests';
      this.logger.log('📮 Running Postman Tests...');
      const postmanResult = await this.executePostmanTests(verbose);
      outputs.push(postmanResult.output);

      // Load fresh results from all files
      const [unitData, e2eData, customData, postmanData] = await Promise.all([
        this.readJestResultFile('test-results-unit.json'),
        this.readJestResultFile('test-results-e2e.json'),
        this.readCustomResultFile('test-results-custom.json'),
        this.readPostmanResultFile('test-results-postman.json'),
      ]);

      const suites: TestSuite[] = [];
      if (unitData)
        suites.push(...this.parseJestResult(unitData, 'jest', 'Unit Tests'));
      if (e2eData)
        suites.push(...this.parseJestResult(e2eData, 'e2e', 'E2E Tests'));
      if (customData) suites.push(...customData);
      if (postmanData) suites.push(...postmanData);

      const summary = this.calculateSummary(suites);
      summary.duration = Date.now() - startTime;

      // Log summary
      const passRate =
        summary.total > 0
          ? Math.round((summary.passed / summary.total) * 100)
          : 0;
      if (summary.failed === 0) {
        this.logger.log(
          `✅ All tests passed! ${summary.passed}/${summary.total} (${passRate}%) in ${summary.duration}ms`,
        );
      } else {
        this.logger.warn(
          `⚠️ Some tests failed: ${summary.passed} passed, ${summary.failed} failed (${passRate}%) in ${summary.duration}ms`,
        );
      }

      this.cachedResults = {
        success: summary.failed === 0,
        suites,
        summary,
        timestamp: new Date().toISOString(),
        rawOutput: outputs.join('\n\n---\n\n'),
      };

      return this.cachedResults;
    } catch (error) {
      this.logger.error(
        `❌ Test execution failed: ${error instanceof Error ? error.message : 'Unknown error'}`,
      );
      throw error;
    } finally {
      this.isRunning = false;
      this.currentTest = null;
    }
  }

  /** Run a specific test type */
  async runTests(testId: string, verbose = true): Promise<RunTestsResponse> {
    if (this.isRunning) {
      throw new Error('Tests are already running');
    }

    const validTypes = ['unit', 'e2e', 'custom', 'postman'];
    if (!validTypes.includes(testId)) {
      throw new Error(`Unknown test type: ${testId}`);
    }

    this.isRunning = true;
    this.currentTest = testId;
    const startTime = Date.now();

    try {
      this.logger.log(`🚀 Running ${testId} tests...`);

      let suites: TestSuite[] = [];

      if (testId === 'unit' || testId === 'e2e') {
        await this.executeJest(testId, verbose);
        const filename =
          testId === 'unit'
            ? 'test-results-unit.json'
            : 'test-results-e2e.json';
        const suiteType = testId === 'unit' ? 'jest' : 'e2e';
        const data = await this.readJestResultFile(filename);
        suites = data
          ? this.parseJestResult(data, suiteType, `${testId} Tests`)
          : [];
      } else if (testId === 'custom') {
        await this.executeCustomTests(verbose);
        const data = await this.readCustomResultFile(
          'test-results-custom.json',
        );
        suites = data || [];
      } else if (testId === 'postman') {
        await this.executePostmanTests(verbose);
        const data = await this.readPostmanResultFile(
          'test-results-postman.json',
        );
        suites = data || [];
      }

      const summary = this.calculateSummary(suites);
      summary.duration = Date.now() - startTime;

      // Log summary
      const passRate =
        summary.total > 0
          ? Math.round((summary.passed / summary.total) * 100)
          : 0;
      if (summary.failed === 0) {
        this.logger.log(
          `✅ ${testId} tests passed! ${summary.passed}/${summary.total} (${passRate}%) in ${summary.duration}ms`,
        );
      } else {
        this.logger.warn(
          `⚠️ ${testId} tests: ${summary.passed} passed, ${summary.failed} failed (${passRate}%)`,
        );
      }

      this.cachedResults = {
        success: summary.failed === 0,
        suites,
        summary,
        timestamp: new Date().toISOString(),
      };

      return this.cachedResults;
    } catch (error) {
      this.logger.error(
        `❌ ${testId} test execution failed: ${error instanceof Error ? error.message : 'Unknown error'}`,
      );
      throw error;
    } finally {
      this.isRunning = false;
      this.currentTest = null;
    }
  }

  /** Execute Jest directly with JSON output */
  private executeJest(
    testType: 'unit' | 'e2e',
    streamOutput = true,
  ): Promise<{ code: number; output: string }> {
    return new Promise((resolve, reject) => {
      const outputFile =
        testType === 'unit'
          ? 'test-results-unit.json'
          : 'test-results-e2e.json';

      const heapSize = testType === 'e2e' ? 2048 : 384;
      let command = `node --max-old-space-size=${heapSize} node_modules/.bin/jest --runInBand --json --outputFile=${outputFile}`;

      if (testType === 'e2e') {
        command += ' --config ./src/test/e2e/jest-e2e.json';
      }

      this.logger.log(`🧪 Running ${testType} tests: ${command}`);

      const proc = spawn(command, [], {
        cwd: process.cwd(),
        shell: true,
        env: { ...process.env, FORCE_COLOR: '1' },
      });

      let output = '';

      proc.stdout?.on('data', (data) => {
        const text = data.toString();
        output += text;
        if (streamOutput) {
          this.streamTestOutput(text, false);
        }
      });

      proc.stderr?.on('data', (data) => {
        const text = data.toString();
        output += text;
        if (streamOutput) {
          this.streamTestOutput(text, true);
        }
      });

      proc.on('close', (code) => {
        // Jest exits with code 1 when tests fail - that's OK
        resolve({ code: code ?? 0, output });
      });

      proc.on('error', (err) => {
        reject(err);
      });
    });
  }

  /** Execute npm script with streamed output parsing (legacy) */
  private executeNpm(
    script: string,
    streamOutput = true,
  ): Promise<{ code: number; output: string }> {
    return new Promise((resolve, reject) => {
      const proc = spawn('npm', ['run', script], {
        cwd: process.cwd(),
        shell: true,
        env: { ...process.env, FORCE_COLOR: '1' }, // Enable colors
      });

      let output = '';

      proc.stdout?.on('data', (data) => {
        const text = data.toString();
        output += text;
        if (streamOutput) {
          // Parse and colorize output
          this.streamTestOutput(text, false);
        }
      });

      proc.stderr?.on('data', (data) => {
        const text = data.toString();
        output += text;
        if (streamOutput) {
          // Stderr is often just Jest's verbose output, not errors
          this.streamTestOutput(text, true);
        }
      });

      proc.on('close', (code) => {
        resolve({ code: code ?? 0, output });
      });

      proc.on('error', (err) => {
        reject(err);
      });
    });
  }

  /** Stream and parse test output with proper log levels */
  private streamTestOutput(text: string, isStderr: boolean): void {
    const lines = text.split('\n').filter((line) => line.trim());

    for (const line of lines) {
      const trimmed = line.trim();

      // Skip empty lines and noise
      if (
        !trimmed ||
        trimmed.startsWith('>') ||
        trimmed.includes('node_modules')
      ) {
        continue;
      }

      // Detect test status from output
      if (trimmed.startsWith('PASS ')) {
        this.logger.log(`✅ ${trimmed}`);
      } else if (trimmed.startsWith('FAIL ')) {
        this.logger.error(`❌ ${trimmed}`);
      } else if (trimmed.includes('✓') || trimmed.includes('✔')) {
        this.logger.log(`   ${trimmed}`);
      } else if (trimmed.includes('✕') || trimmed.includes('✗')) {
        this.logger.error(`   ${trimmed}`);
      } else if (
        trimmed.startsWith('Test Suites:') ||
        trimmed.startsWith('Tests:') ||
        trimmed.startsWith('Time:')
      ) {
        this.logger.log(trimmed);
      } else if (trimmed.includes('passed') && !trimmed.includes('failed')) {
        this.logger.log(trimmed);
      } else if (trimmed.includes('failed')) {
        this.logger.warn(trimmed);
      } else if (
        isStderr &&
        (trimmed.includes('Error') || trimmed.includes('error'))
      ) {
        this.logger.error(trimmed);
      } else {
        // Default: log at debug level for verbose output
        this.logger.debug(trimmed);
      }
    }
  }

  /** Read Jest JSON result file */
  private async readJestResultFile(
    filename: string,
  ): Promise<JestResult | null> {
    try {
      const filePath = path.join(process.cwd(), filename);
      if (!fs.existsSync(filePath)) {
        this.logger.debug(`Test results file not found: ${filename}`);
        return null;
      }
      const content = fs.readFileSync(filePath, 'utf-8');
      return JSON.parse(content) as JestResult;
    } catch (error) {
      this.logger.error(`Failed to read ${filename}`, error);
      return null;
    }
  }

  /** Parse Jest result into our TestSuite format */
  private parseJestResult(
    data: JestResult,
    type: 'jest' | 'e2e' | 'postman',
    suiteName: string,
  ): TestSuite[] {
    const suites: TestSuite[] = [];

    for (const testFile of data.testResults) {
      const fileName = path.basename(testFile.name);
      const tests: TestResult[] = [];
      let passed = 0;
      let failed = 0;
      let totalDuration = 0;

      for (const assertion of testFile.assertionResults) {
        const status = this.mapAssertionStatus(assertion.status);

        if (status === 'passed') passed++;
        else if (status === 'failed') failed++;

        const duration = assertion.duration || 0;
        totalDuration += duration;

        tests.push({
          id: `${type}-${fileName}-${tests.length}`,
          name: assertion.fullName || assertion.title,
          status,
          duration,
          error: assertion.failureMessages.join('\n') || undefined,
        });
      }

      suites.push({
        name: fileName,
        type,
        tests,
        totalPassed: passed,
        totalFailed: failed,
        totalDuration,
      });
    }

    return suites;
  }

  /** Map Jest assertion status to our status type */
  private mapAssertionStatus(
    jestStatus: string,
  ): 'passed' | 'failed' | 'skipped' {
    if (jestStatus === 'passed') return 'passed';
    if (jestStatus === 'failed') return 'failed';
    return 'skipped';
  }

  /** Calculate summary from suites */
  private calculateSummary(suites: TestSuite[]): {
    total: number;
    passed: number;
    failed: number;
    duration: number;
  } {
    let total = 0,
      passed = 0,
      failed = 0,
      duration = 0;
    for (const suite of suites) {
      total += suite.tests.length;
      passed += suite.totalPassed;
      failed += suite.totalFailed;
      duration += suite.totalDuration;
    }
    return { total, passed, failed, duration };
  }

  /** Execute custom unit tests */
  private executeCustomTests(
    streamOutput = true,
  ): Promise<{ code: number; output: string }> {
    return new Promise((resolve) => {
      const startTime = Date.now();
      const customTestsDir = path.join(process.cwd(), 'src/test/unit_tests');
      const outputFile = path.join(process.cwd(), 'test-results-custom.json');

      // Check if custom tests directory exists
      if (!fs.existsSync(customTestsDir)) {
        this.logger.warn('Custom tests directory not found');
        fs.writeFileSync(outputFile, JSON.stringify([]));
        resolve({ code: 0, output: 'No custom tests found' });
        return;
      }

      // Get all test files (excluding base.test.ts which is the base class)
      const testFiles = fs
        .readdirSync(customTestsDir)
        .filter((f) => f.endsWith('.test.ts') && f !== 'base.test.ts');

      if (testFiles.length === 0) {
        fs.writeFileSync(outputFile, JSON.stringify([]));
        resolve({ code: 0, output: 'No custom test files found' });
        return;
      }

      // Run custom tests using ts-node
      const command = `npx ts-node --transpile-only -e "
        const fs = require('fs');
        const path = require('path');
        
        async function runTests() {
          const results = [];
          const testDir = '${customTestsDir.replaceAll('\\', '\\\\')}';
          const files = ${JSON.stringify(testFiles)};
          
          for (const file of files) {
            try {
              const testModule = require(path.join(testDir, file));
              const TestClass = Object.values(testModule).find(v => typeof v === 'function' && v.prototype?.run);
              
              if (TestClass) {
                const instance = new TestClass();
                const result = await instance.run();
                results.push({
                  file,
                  name: instance.name || file,
                  description: instance.description || '',
                  ...result
                });
                console.log(result.passed ? 'PASS' : 'FAIL', file, '-', result.message);
              }
            } catch (err) {
              results.push({
                file,
                name: file,
                passed: false,
                message: err.message || 'Test execution failed',
                duration: 0,
                errors: [err.message]
              });
              console.error('FAIL', file, '-', err.message);
            }
          }
          
          console.log(JSON.stringify(results));
        }
        
        runTests();
      "`;

      const proc = spawn(command, [], {
        cwd: process.cwd(),
        shell: true,
        env: { ...process.env },
      });

      let output = '';
      let jsonOutput = '';

      proc.stdout?.on('data', (data) => {
        const text = data.toString();
        output += text;

        // Try to extract JSON from output
        const lines = text.split('\n');
        for (const line of lines) {
          if (line.trim().startsWith('[') && line.trim().endsWith(']')) {
            jsonOutput = line.trim();
          } else if (line.startsWith('PASS') || line.startsWith('FAIL')) {
            if (streamOutput) {
              if (line.startsWith('PASS')) {
                this.logger.log(`✅ ${line}`);
              } else {
                this.logger.error(`❌ ${line}`);
              }
            }
          }
        }
      });

      proc.stderr?.on('data', (data) => {
        output += data.toString();
      });

      proc.on('close', (code) => {
        const duration = Date.now() - startTime;

        // Parse results and write to file
        try {
          const results = jsonOutput ? JSON.parse(jsonOutput) : [];
          const suites = this.convertCustomResultsToSuites(results);
          fs.writeFileSync(outputFile, JSON.stringify(suites));

          const passed = results.filter(
            (r: CustomTestResult) => r.passed,
          ).length;
          const failed = results.filter(
            (r: CustomTestResult) => !r.passed,
          ).length;

          this.logger.log(
            `Custom tests: ${passed} passed, ${failed} failed in ${duration}ms`,
          );
        } catch {
          fs.writeFileSync(outputFile, JSON.stringify([]));
        }

        resolve({ code: code ?? 0, output });
      });

      proc.on('error', () => {
        fs.writeFileSync(outputFile, JSON.stringify([]));
        resolve({ code: 1, output: 'Failed to execute custom tests' });
      });
    });
  }

  /** Convert custom test results to TestSuite format */
  private convertCustomResultsToSuites(
    results: CustomTestResult[],
  ): TestSuite[] {
    if (!results || results.length === 0) return [];

    const tests: TestResult[] = results.map((r, idx) => ({
      id: `custom-${idx}`,
      name: r.name || `Test ${idx + 1}`,
      status: r.passed ? ('passed' as const) : ('failed' as const),
      duration: r.duration || 0,
      error: r.errors?.join('\n'),
    }));

    const passed = tests.filter((t) => t.status === 'passed').length;
    const failed = tests.filter((t) => t.status === 'failed').length;
    const totalDuration = tests.reduce((sum, t) => sum + (t.duration || 0), 0);

    return [
      {
        name: 'custom-unit-tests',
        type: 'custom',
        tests,
        totalPassed: passed,
        totalFailed: failed,
        totalDuration,
      },
    ];
  }

  /** Read custom test results file */
  private async readCustomResultFile(
    filename: string,
  ): Promise<TestSuite[] | null> {
    return this.readResultFile(filename);
  }

  /** Execute Postman tests using Newman */
  private executePostmanTests(
    streamOutput = true,
  ): Promise<{ code: number; output: string }> {
    return new Promise((resolve) => {
      const startTime = Date.now();
      const postmanDir = path.join(process.cwd(), 'postman');
      const outputFile = path.join(process.cwd(), 'test-results-postman.json');
      const collectionFile = path.join(
        postmanDir,
        'vite-gourmand-ecf-complete.json',
      );
      const envFile = path.join(postmanDir, 'env.local.json');

      // Check if collection exists
      if (!fs.existsSync(collectionFile)) {
        this.logger.warn('Postman collection not found');
        fs.writeFileSync(outputFile, JSON.stringify([]));
        resolve({ code: 0, output: 'No Postman collection found' });
        return;
      }

      // Build newman command
      let command = `npx newman run "${collectionFile}" --reporters cli,json --reporter-json-export test-results-postman-raw.json`;

      if (fs.existsSync(envFile)) {
        command += ` --environment "${envFile}"`;
      }

      this.logger.log(
        `📮 Running Postman tests: ${path.basename(collectionFile)}`,
      );

      const proc = spawn(command, [], {
        cwd: process.cwd(),
        shell: true,
        env: { ...process.env },
      });

      let output = '';

      proc.stdout?.on('data', (data) => {
        const text = data.toString();
        output += text;
        if (streamOutput) {
          this.streamPostmanOutput(text);
        }
      });

      proc.stderr?.on('data', (data) => {
        output += data.toString();
      });

      proc.on('close', (code) => {
        const duration = Date.now() - startTime;

        // Parse Newman JSON output and convert to our format
        try {
          const rawResultPath = path.join(
            process.cwd(),
            'test-results-postman-raw.json',
          );
          if (fs.existsSync(rawResultPath)) {
            const rawResult = JSON.parse(
              fs.readFileSync(rawResultPath, 'utf-8'),
            ) as NewmanResult;
            const suites = this.parseNewmanResult(rawResult);
            fs.writeFileSync(outputFile, JSON.stringify(suites));

            const stats = rawResult.run?.stats?.assertions || {
              total: 0,
              failed: 0,
            };
            const passed = stats.total - stats.failed;
            this.logger.log(
              `Postman tests: ${passed} passed, ${stats.failed} failed in ${duration}ms`,
            );
          } else {
            fs.writeFileSync(outputFile, JSON.stringify([]));
          }
        } catch (err) {
          this.logger.error('Failed to parse Postman results', err);
          fs.writeFileSync(outputFile, JSON.stringify([]));
        }

        resolve({ code: code ?? 0, output });
      });

      proc.on('error', (err) => {
        this.logger.error('Failed to run Postman tests', err);
        fs.writeFileSync(outputFile, JSON.stringify([]));
        resolve({ code: 1, output: 'Failed to execute Postman tests' });
      });
    });
  }

  /** Parse Newman result into TestSuite format */
  private parseNewmanResult(result: NewmanResult): TestSuite[] {
    if (!result?.run?.executions) return [];

    const tests: TestResult[] = [];
    let passed = 0;
    let failed = 0;
    let totalDuration = 0;

    for (const execution of result.run.executions) {
      const itemName = execution.item?.name || 'Unknown Request';
      const responseTime = execution.response?.responseTime || 0;
      totalDuration += responseTime;

      // Each execution can have multiple assertions
      const assertions = execution.assertions || [];

      if (assertions.length === 0) {
        // No assertions - count as passed if no error
        tests.push({
          id: `postman-${tests.length}`,
          name: itemName,
          status: 'passed',
          duration: responseTime,
        });
        passed++;
      } else {
        for (const assertion of assertions) {
          const hasFailed = !!assertion.error;
          tests.push({
            id: `postman-${tests.length}`,
            name: `${itemName}: ${assertion.assertion}`,
            status: hasFailed ? 'failed' : 'passed',
            duration: responseTime / assertions.length,
            error: assertion.error?.message,
          });

          if (hasFailed) failed++;
          else passed++;
        }
      }
    }

    return [
      {
        name: result.collection?.info?.name || 'Postman Collection',
        type: 'postman',
        tests,
        totalPassed: passed,
        totalFailed: failed,
        totalDuration,
      },
    ];
  }

  /** Read Postman test results file */
  private async readPostmanResultFile(
    filename: string,
  ): Promise<TestSuite[] | null> {
    return this.readResultFile(filename);
  }

  /** Generic result file reader */
  private readResultFile(filename: string): TestSuite[] | null {
    try {
      const filePath = path.join(process.cwd(), filename);
      if (!fs.existsSync(filePath)) {
        return null;
      }
      const content = fs.readFileSync(filePath, 'utf-8');
      return JSON.parse(content) as TestSuite[];
    } catch {
      return null;
    }
  }

  /** Stream Postman test output */
  private streamPostmanOutput(text: string): void {
    const lines = text.split('\n').filter((line) => line.trim());

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      if (trimmed.includes('✓') || trimmed.includes('✔')) {
        this.logger.log(`   ${trimmed}`);
      } else if (
        trimmed.includes('✗') ||
        trimmed.includes('✕') ||
        trimmed.includes('failed')
      ) {
        this.logger.error(`   ${trimmed}`);
      } else if (
        trimmed.includes('assertions') ||
        trimmed.includes('requests')
      ) {
        this.logger.log(trimmed);
      } else {
        this.logger.debug(trimmed);
      }
    }
  }

  // Legacy methods for backward compatibility
  async getUnitTestResults(): Promise<LegacyTestSuite[]> {
    const data = await this.readJestResultFile('test-results-unit.json');
    return data ? this.convertJestToLegacy(data) : [];
  }

  async getE2eTestResults(): Promise<LegacyTestSuite[]> {
    const data = await this.readJestResultFile('test-results-e2e.json');
    return data ? this.convertJestToLegacy(data) : [];
  }

  async getSummary(): Promise<{
    unit: LegacyTestSuite[];
    e2e: LegacyTestSuite[];
  }> {
    const [unit, e2e] = await Promise.all([
      this.getUnitTestResults(),
      this.getE2eTestResults(),
    ]);
    return { unit, e2e };
  }

  /** Convert Jest result to legacy format */
  private convertJestToLegacy(data: JestResult): LegacyTestSuite[] {
    return data.testResults.map((file) => ({
      name: path.basename(file.name),
      tests: file.assertionResults.map((a) => ({
        name: a.fullName || a.title,
        status: this.mapAssertionStatus(a.status),
        duration: a.duration,
        error: a.failureMessages.join('\n') || undefined,
      })),
      passed: file.assertionResults.filter((a) => a.status === 'passed').length,
      failed: file.assertionResults.filter((a) => a.status === 'failed').length,
      skipped: file.assertionResults.filter(
        (a) => a.status === 'pending' || a.status === 'skipped',
      ).length,
    }));
  }
}

/** Legacy format for backward compatibility */
export interface LegacyTestSuite {
  name: string;
  tests: {
    name: string;
    status: 'passed' | 'failed' | 'skipped';
    duration?: number;
    error?: string;
  }[];
  passed: number;
  failed: number;
  skipped: number;
}
