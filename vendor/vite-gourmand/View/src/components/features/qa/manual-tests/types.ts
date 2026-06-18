/**
 * Manual test types
 */

export type ManualTestResult = 'pending' | 'passed' | 'failed' | 'blocked';

export interface ManualTestStep {
  id: string;
  instruction: string;
  expected: string;
}

export interface ManualTest {
  id: string;
  title: string;
  description: string;
  steps: ManualTestStep[];
  result: ManualTestResult;
  notes?: string;
  testedAt?: Date;
}
