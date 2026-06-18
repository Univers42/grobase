/**
 * useTestRunner Hook
 * Manages test execution state and results
 */

import { useState, useCallback, useEffect } from 'react';
import {
  runTests,
  runAllTests,
  getTestResults,
  TEST_CONFIGS,
  type TestConfigId,
  type RunTestsResponse,
} from '../../services/testRunner';
import type { AutoTest, TestSuite as UISuite } from '../features/qa/automatic-tests';

interface UseTestRunnerReturn {
  // State
  isRunning: boolean;
  currentTest: string | null;
  results: RunTestsResponse | null;
  error: string | null;
  rawOutput: string | null;

  // Derived data
  autoTests: AutoTest[];
  suites: UISuite[];
  metrics: {
    total: number;
    passed: number;
    failed: number;
    passRate: number;
    duration: number;
    lastRun: Date | null;
    suiteCount: number;
  };

  // Actions
  runTest: (testId: TestConfigId) => Promise<void>;
  runSuite: (suiteName: string) => Promise<void>;
  runType: (type: 'unit' | 'e2e' | 'custom' | 'postman') => Promise<void>;
  runAll: () => Promise<void>;
  refresh: () => Promise<void>;
}

/**
 * Convert API results to AutoTest format for display
 */
function toAutoTests(results: RunTestsResponse | null): AutoTest[] {
  if (!results?.suites?.length) return [];

  return results.suites.flatMap((suite) =>
    (suite.tests || []).map((test) => ({
      id: test.id,
      name: test.name,
      suite: suite.name,
      status: test.status,
      duration: test.duration,
      output: test.output,
      error: test.error,
    })),
  );
}

/**
 * Convert API suites to UI format
 */
function toUISuites(results: RunTestsResponse | null): UISuite[] {
  if (!results?.suites?.length) return [];

  return results.suites.map((suite) => ({
    name: suite.name,
    type: suite.type,
    tests: (suite.tests || []).map((test) => ({
      id: test.id,
      name: test.name,
      suite: suite.name,
      status: test.status,
      duration: test.duration,
      output: test.output,
      error: test.error,
    })),
    totalPassed: suite.totalPassed,
    totalFailed: suite.totalFailed,
    totalDuration: suite.totalDuration,
  }));
}

/**
 * Calculate metrics from results
 */
function calculateMetrics(results: RunTestsResponse | null) {
  if (!results?.summary) {
    // No data yet — return -1 passRate to distinguish from actual 0% failure
    return {
      total: 0,
      passed: 0,
      failed: 0,
      passRate: -1,
      duration: 0,
      lastRun: null,
      suiteCount: 0,
    };
  }

  const { total = 0, passed = 0, failed = 0, duration = 0 } = results.summary;
  const suiteCount = results.suites?.length ?? 0;
  // -1 signals 'no data / pending' to the UI so it doesn't show 'critical'
  const passRate = total > 0 ? Math.round((passed / total) * 100) : -1;
  const lastRun = results.timestamp ? new Date(results.timestamp) : null;

  return { total, passed, failed, passRate, duration, lastRun, suiteCount };
}
export function useTestRunner(): UseTestRunnerReturn {
  const [isRunning, setIsRunning] = useState(false);
  const [currentTest, setCurrentTest] = useState<string | null>(null);
  const [results, setResults] = useState<RunTestsResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [rawOutput, setRawOutput] = useState<string | null>(null);

  // Load cached results from backend on mount — DO NOT auto-run
  useEffect(() => {
    let isMounted = true;

    const loadCachedResults = async () => {
      try {
        const cached = await getTestResults();
        if (!isMounted) return;

        if (cached?.suites?.length) {
          // Cache has data — use it
          setResults(cached);
          if (cached.rawOutput) setRawOutput(cached.rawOutput);
        }
        // If no cache, just leave it empty — user will click "Run All" when ready
      } catch {
        // Backend not available — silently fail
        if (isMounted) {
          console.log('Test results API not available - backend may not be running');
        }
      }
    };

    loadCachedResults();

    return () => {
      isMounted = false;
    };
  }, []);

  const runTest = useCallback(async (testId: TestConfigId) => {
    setIsRunning(true);
    setCurrentTest(TEST_CONFIGS[testId].name);
    setError(null);
    // Reset results to show "running" state with zeroed metrics
    setResults(null);
    setRawOutput(null);

    try {
      // Always request verbose output to show CLI results
      const response = await runTests(testId, { verbose: true });
      setResults(response);
      if (response.rawOutput) setRawOutput(response.rawOutput);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Test run failed');
    } finally {
      setIsRunning(false);
      setCurrentTest(null);
    }
  }, []);

  const runSuite = useCallback(async (suiteName: string) => {
    // Determine if it's unit or e2e based on filename pattern
    const isE2E = suiteName.includes('.e2e-spec') || suiteName.includes('/e2e/');
    const testType = isE2E ? 'e2e' : 'unit';

    setIsRunning(true);
    setCurrentTest(suiteName);
    setError(null);
    // Reset results to show "running" state with zeroed metrics
    setResults(null);
    setRawOutput(null);

    try {
      // Run the appropriate test type
      const response = await runTests(testType, { verbose: true });
      setResults(response);
      if (response.rawOutput) setRawOutput(response.rawOutput);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Test run failed');
    } finally {
      setIsRunning(false);
      setCurrentTest(null);
    }
  }, []);

  const runType = useCallback(async (type: 'unit' | 'e2e' | 'custom' | 'postman') => {
    setIsRunning(true);
    const typeLabels: Record<string, string> = {
      unit: 'Unit Tests',
      e2e: 'E2E Tests',
      custom: 'Custom Tests',
      postman: 'Postman Tests',
    };
    setCurrentTest(typeLabels[type] || type);
    setError(null);
    // Reset results to show "running" state with zeroed metrics
    setResults(null);
    setRawOutput(null);

    try {
      const response = await runTests(type, { verbose: true });
      setResults(response);
      if (response.rawOutput) setRawOutput(response.rawOutput);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Test run failed');
    } finally {
      setIsRunning(false);
      setCurrentTest(null);
    }
  }, []);

  const runAll = useCallback(async () => {
    setIsRunning(true);
    setCurrentTest('All Tests');
    setError(null);
    // Reset results to show "running" state with zeroed metrics
    setResults(null);
    setRawOutput(null);

    try {
      // Always request verbose output to show CLI results
      const response = await runAllTests({ verbose: true });
      setResults(response);
      if (response.rawOutput) setRawOutput(response.rawOutput);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Test run failed - is the backend running?');
    } finally {
      setIsRunning(false);
      setCurrentTest(null);
    }
  }, []);

  const refresh = useCallback(async () => {
    try {
      const cached = await getTestResults();
      if (cached) {
        setResults(cached);
        if (cached.rawOutput) setRawOutput(cached.rawOutput);
      }
    } catch {
      // Ignore refresh errors
    }
  }, []);

  return {
    isRunning,
    currentTest,
    results,
    error,
    rawOutput,
    autoTests: toAutoTests(results),
    suites: toUISuites(results),
    metrics: calculateMetrics(results),
    runTest,
    runSuite,
    runType,
    runAll,
    refresh,
  };
}
