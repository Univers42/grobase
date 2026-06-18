/**
 * Automatic test types
 */

export type AutoTestStatus = 'idle' | 'running' | 'passed' | 'failed' | 'skipped';

export interface AutoTest {
  id: string;
  name: string;
  suite: string;
  status: AutoTestStatus;
  duration?: number;
  output?: string;
  error?: string;
}

export interface TestSuite {
  name: string;
  type: 'jest' | 'e2e' | 'postman' | 'custom';
  tests: AutoTest[];
  totalPassed: number;
  totalFailed: number;
  totalDuration: number;
}
