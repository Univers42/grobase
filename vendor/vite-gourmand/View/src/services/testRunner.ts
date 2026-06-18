/**
 * Test Runner Service
 * API service to run and fetch backend test results
 */

import { apiRequest } from './api';

type ApiWrapper<T> = T | { data: T };

function unwrapApiData<T>(response: ApiWrapper<T>): T {
  if (typeof response === 'object' && response !== null && 'data' in response) {
    return response.data;
  }
  return response;
}

export interface TestResult {
  id: string;
  name: string;
  suite: string;
  status: 'idle' | 'running' | 'passed' | 'failed';
  duration?: number;
  error?: string;
  output?: string;
}

export interface TestSuite {
  name: string;
  type: 'jest' | 'postman' | 'e2e' | 'custom';
  tests: TestResult[];
  totalPassed: number;
  totalFailed: number;
  totalDuration: number;
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
  timestamp?: string;
  rawOutput?: string; // Verbose CLI output
}

export interface TestRunOptions {
  verbose?: boolean;
}

/**
 * Available test configurations
 */
export const TEST_CONFIGS = {
  unit: {
    id: 'unit',
    name: 'Unit Tests',
    command: 'npm test',
    description: 'Jest unit tests for services and controllers',
    type: 'jest' as const,
  },
  e2e: {
    id: 'e2e',
    name: 'E2E Tests',
    command: 'npm run test:e2e',
    description: 'End-to-end API tests',
    type: 'jest' as const,
  },
  custom: {
    id: 'custom',
    name: 'Custom Tests',
    command: 'ts-node',
    description: 'Custom unit tests in src/test/unit_tests',
    type: 'custom' as const,
  },
  postman: {
    id: 'postman',
    name: 'Postman Collection',
    command: 'newman run',
    description: 'Postman API collection tests',
    type: 'postman' as const,
  },
  orders: {
    id: 'orders',
    name: 'Orders API',
    command: 'npm run test:orders',
    description: 'Order flow integration tests',
    type: 'jest' as const,
  },
};

export type TestConfigId = keyof typeof TEST_CONFIGS;

/**
 * Run a specific test suite
 */
export async function runTests(
  testId: TestConfigId,
  options: TestRunOptions = {},
): Promise<RunTestsResponse> {
  try {
    const response = await apiRequest<ApiWrapper<RunTestsResponse>>('/api/tests/run', {
      method: 'POST',
      body: { testId, verbose: options.verbose },
    });
    return unwrapApiData(response); // Backend wraps response in data property
  } catch (error) {
    console.error('Failed to run tests:', error);
    throw error;
  }
}

/**
 * Run all test suites
 */
export async function runAllTests(options: TestRunOptions = {}): Promise<RunTestsResponse> {
  try {
    const response = await apiRequest<ApiWrapper<RunTestsResponse>>('/api/tests/run-all', {
      method: 'POST',
      body: { verbose: options.verbose },
    });
    return unwrapApiData(response); // Backend wraps response in data property
  } catch (error) {
    console.error('Failed to run all tests:', error);
    throw error;
  }
}

/**
 * Get latest test results from cache
 * Returns null silently if no results available (404 is expected)
 */
export async function getTestResults(): Promise<RunTestsResponse | null> {
  try {
    const response = await apiRequest<ApiWrapper<RunTestsResponse>>('/api/tests/results');
    return unwrapApiData(response); // Backend wraps response in data property
  } catch {
    // Silent fail - API might not be available
    return null;
  }
}

/**
 * Get test status (running/idle)
 */
export async function getTestStatus(): Promise<{ running: boolean; currentTest?: string }> {
  try {
    const response =
      await apiRequest<ApiWrapper<{ running: boolean; currentTest?: string }>>('/api/tests/status');
    return unwrapApiData(response); // Backend wraps response in data property
  } catch (error) {
    console.error('Failed to fetch test status:', error);
    return { running: false };
  }
}

/**
 * Parse Jest output into structured results
 */
export function parseJestOutput(output: string): TestResult[] {
  const results: TestResult[] = [];
  const lines = output.split('\n');
  const suitePattern = /^\s*(PASS|FAIL)\s+(.+\.spec\.ts)/;
  const testPattern = /^\s*([✓✕○])\s+(.+?)\s*(?:\((\d+)\s*ms\))?$/;

  let currentSuite = '';

  for (const line of lines) {
    // Match test suite
    const suiteMatch = suitePattern.exec(line);
    if (suiteMatch) {
      currentSuite = suiteMatch[2];
    }

    // Match individual test
    const testMatch = testPattern.exec(line);
    if (testMatch) {
      const [, icon, name, duration] = testMatch;
      results.push({
        id: `${currentSuite}-${name}`.replace(/\s+/g, '-').toLowerCase(),
        name,
        suite: currentSuite,
        status: getParsedTestStatus(icon),
        duration: duration ? Number.parseInt(duration, 10) : undefined,
      });
    }
  }

  return results;
}

function getParsedTestStatus(icon: string): TestResult['status'] {
  if (icon === '✓') return 'passed';
  if (icon === '✕') return 'failed';
  return 'idle';
}

/**
 * Mock test data for development (when backend is not available)
 * Generates fresh results each time with random variations
 * Note: These are SIMULATED results. For real tests, use:
 * - Backend: `make test` or `npm run test`
 * - Postman: `make test:postman` or `npm run test:postman`
 */
export function getMockTestResults(): RunTestsResponse {
  // Random slight variations in timing to simulate real tests
  const randomDuration = (base: number) => Math.max(1, base + Math.floor(Math.random() * 20) - 10);

  // Create timestamp to track when this run was generated
  const runId = Date.now();

  // Mock CLI output for demo purposes
  const mockUnitOutput = `PASS  src/app.controller.spec.ts
  AppController
    ✓ should return hello (12 ms)
    ✓ should return version (8 ms)

PASS  src/order.service.spec.ts  
  OrderService
    ✓ should create order (45 ms)
    ✓ should validate items (23 ms)

PASS  src/guards.spec.ts
  Guards › JwtAuthGuard
    ✓ should allow valid token (15 ms)
  Guards › RolesGuard  
    ✓ should block unauthorized (11 ms)

Test Suites: 3 passed, 3 total
Tests:       6 passed, 6 total
Snapshots:   0 total
Time:        2.541 s`;

  const mockPostmanOutput = `newman

vite-gourmand-complete

→ Auth › Login with valid credentials
  POST http://localhost:3000/api/auth/login [200 OK, 234ms]
  ✓ Status code is 200
  ✓ Response has token

→ Auth › Register new user
  POST http://localhost:3000/api/auth/register [201 Created, 189ms]
  ✓ Status code is 201

→ Orders › Create new order
  POST http://localhost:3000/api/orders [201 Created, 312ms]
  ✓ Order created successfully

→ Orders › List user orders
  GET http://localhost:3000/api/orders [200 OK, 156ms]
  ✓ Returns array of orders

→ Admin › Get dashboard stats
  GET http://localhost:3000/api/admin/stats [200 OK, 98ms]
  ✓ Returns dashboard statistics`;

  // Unit tests are generally stable - use consistent statuses
  const tests: Array<{
    id: string;
    name: string;
    suite: string;
    status: 'passed' | 'failed';
    duration: number;
    output?: string;
  }> = [
    {
      id: `app-ctrl-1-${runId}`,
      name: 'AppController › should return hello',
      suite: 'app.controller.spec.ts',
      status: 'passed',
      duration: randomDuration(12),
      output: mockUnitOutput,
    },
    {
      id: `app-ctrl-2-${runId}`,
      name: 'AppController › should return version',
      suite: 'app.controller.spec.ts',
      status: 'passed',
      duration: randomDuration(8),
      output: mockUnitOutput,
    },
    {
      id: `order-svc-1-${runId}`,
      name: 'OrderService › should create order',
      suite: 'order.service.spec.ts',
      status: 'passed',
      duration: randomDuration(45),
      output: mockUnitOutput,
    },
    {
      id: `order-svc-2-${runId}`,
      name: 'OrderService › should validate items',
      suite: 'order.service.spec.ts',
      status: 'passed',
      duration: randomDuration(23),
      output: mockUnitOutput,
    },
    {
      id: `guards-1-${runId}`,
      name: 'Guards › JwtAuthGuard › should allow valid token',
      suite: 'guards.spec.ts',
      status: 'passed',
      duration: randomDuration(15),
      output: mockUnitOutput,
    },
    {
      id: `guards-2-${runId}`,
      name: 'Guards › RolesGuard › should block unauthorized',
      suite: 'guards.spec.ts',
      status: 'passed',
      duration: randomDuration(11),
      output: mockUnitOutput,
    },
  ];

  // Postman tests - these depend on backend state and can have issues
  // Simulating realistic scenarios where backend may not be ready
  const postmanTests: Array<{
    id: string;
    name: string;
    suite: string;
    status: 'passed' | 'failed';
    duration: number;
    output?: string;
  }> = [
    {
      id: `auth-login-${runId}`,
      name: 'Auth › Login with valid credentials',
      suite: 'auth.json',
      status: 'passed',
      duration: randomDuration(234),
      output: mockPostmanOutput,
    },
    {
      id: `auth-register-${runId}`,
      name: 'Auth › Register new user',
      suite: 'auth.json',
      status: 'passed',
      duration: randomDuration(189),
      output: mockPostmanOutput,
    },
    {
      id: `orders-create-${runId}`,
      name: 'Orders › Create new order',
      suite: 'orders.json',
      status: 'passed',
      duration: randomDuration(312),
      output: mockPostmanOutput,
    },
    {
      id: `orders-list-${runId}`,
      name: 'Orders › List user orders',
      suite: 'orders.json',
      status: 'passed',
      duration: randomDuration(156),
      output: mockPostmanOutput,
    },
    {
      id: `admin-stats-${runId}`,
      name: 'Admin › Get dashboard stats',
      suite: 'admin.json',
      status: 'passed',
      duration: randomDuration(98),
      output: mockPostmanOutput,
    },
  ];

  const unitPassed = tests.length; // All passed in mock
  const unitFailed = 0;
  const unitDuration = tests.reduce((sum, t) => sum + (t.duration || 0), 0);

  const postmanPassed = postmanTests.length; // All passed in mock
  const postmanFailed = 0;
  const postmanDuration = postmanTests.reduce((sum, t) => sum + (t.duration || 0), 0);

  return {
    success: unitFailed + postmanFailed === 0,
    suites: [
      {
        name: 'Unit Tests',
        type: 'jest',
        tests,
        totalPassed: unitPassed,
        totalFailed: unitFailed,
        totalDuration: unitDuration,
      },
      {
        name: 'Postman Collection',
        type: 'postman',
        tests: postmanTests,
        totalPassed: postmanPassed,
        totalFailed: postmanFailed,
        totalDuration: postmanDuration,
      },
    ],
    summary: {
      total: tests.length + postmanTests.length,
      passed: unitPassed + postmanPassed,
      failed: unitFailed + postmanFailed,
      duration: unitDuration + postmanDuration,
    },
  };
}
