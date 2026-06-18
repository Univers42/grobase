/**
 * Test card types for QA feature
 */

export type TestStatus = 'idle' | 'running' | 'success' | 'failed' | 'pending';
export type TestType = 'automatic' | 'manual' | 'api' | 'database' | 'security' | 'scenario';

export interface TestItem {
  id: string;
  name: string;
  description?: string;
  status: TestStatus;
  type: TestType;
  duration?: number;
  lastRun?: Date;
  /** URL path for manual test pages */
  testPath?: string;
}
