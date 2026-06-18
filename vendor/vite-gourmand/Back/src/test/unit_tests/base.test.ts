/**
 * Base Test Class
 * Abstract class that all tests must extend
 * Provides common interface for test execution and fuzzy testing
 */

export interface TestResult {
  name: string;
  passed: boolean;
  message: string;
  duration: number;
  details?: Record<string, unknown>;
  errors?: string[];
}

export interface FuzzyTestResult {
  iterations: number;
  passed: number;
  failed: number;
  results: TestResult[];
  failedCases: TestResult[];
}

export interface TestConfig {
  timeout?: number;
  retries?: number;
  verbose?: boolean;
}

export abstract class BaseTest {
  abstract name: string;
  abstract description: string;
  abstract category: string;

  protected config: TestConfig;

  constructor(config?: TestConfig) {
    this.config = {
      timeout: 30000,
      retries: 0,
      verbose: false,
      ...config,
    };
  }

  /**
   * Main test execution method - must be implemented
   */
  abstract run(): Promise<TestResult>;

  /**
   * Fuzzy testing method - should be overridden for fuzz testing
   */
  async fuzzyRun(iterations: number = 100): Promise<FuzzyTestResult> {
    const results: TestResult[] = [];
    const failedCases: TestResult[] = [];

    for (let i = 0; i < iterations; i++) {
      try {
        const result = await this.run();
        results.push(result);
        if (!result.passed) {
          failedCases.push(result);
        }
      } catch (error) {
        const errorResult = this.failure(
          `Iteration ${i + 1} threw error: ${String(error)}`,
        );
        results.push(errorResult);
        failedCases.push(errorResult);
      }
    }

    return {
      iterations,
      passed: results.filter((r) => r.passed).length,
      failed: results.filter((r) => !r.passed).length,
      results,
      failedCases,
    };
  }

  /**
   * Create a success result
   */
  protected success(
    message: string,
    details?: Record<string, unknown>,
  ): TestResult {
    return {
      name: this.name,
      passed: true,
      message,
      duration: 0,
      details,
    };
  }

  /**
   * Create a failure result
   */
  protected failure(
    message: string,
    errors?: string[],
    details?: Record<string, unknown>,
  ): TestResult {
    return {
      name: this.name,
      passed: false,
      message,
      duration: 0,
      errors,
      details,
    };
  }

  /**
   * Assert helper
   */
  protected assert(condition: boolean, message: string): void {
    if (!condition) {
      throw new Error(`Assertion failed: ${message}`);
    }
  }

  /**
   * Assert equals helper
   */
  protected assertEqual<T>(actual: T, expected: T, message: string): void {
    if (actual !== expected) {
      throw new Error(
        `Assertion failed: ${message}. Expected: ${String(expected)}, Got: ${String(actual)}`,
      );
    }
  }

  /**
   * Assert throws helper
   */
  protected async assertThrows(
    fn: () => Promise<unknown>,
    message: string,
  ): Promise<void> {
    let threw = false;
    try {
      await fn();
    } catch {
      threw = true;
    }
    if (!threw) {
      throw new Error(
        `Assertion failed: ${message}. Expected function to throw.`,
      );
    }
  }

  /**
   * Measure execution time
   */
  protected async measure<T>(
    fn: () => Promise<T>,
  ): Promise<{ result: T; duration: number }> {
    const start = performance.now();
    const result = await fn();
    const duration = Math.round(performance.now() - start);
    return { result, duration };
  }
}

/**
 * Test Registry for dynamic test discovery
 */
export class TestRegistry {
  private static tests: Map<string, BaseTest> = new Map();

  static register(test: BaseTest): void {
    this.tests.set(test.name, test);
  }

  static get(name: string): BaseTest | undefined {
    return this.tests.get(name);
  }

  static getAll(): BaseTest[] {
    return Array.from(this.tests.values());
  }

  static getByCategory(category: string): BaseTest[] {
    return this.getAll().filter((t) => t.category === category);
  }

  static getCategories(): string[] {
    const categories = new Set(this.getAll().map((t) => t.category));
    return Array.from(categories);
  }

  static listTests(): {
    name: string;
    description: string;
    category: string;
  }[] {
    return this.getAll().map((t) => ({
      name: t.name,
      description: t.description,
      category: t.category,
    }));
  }
}
