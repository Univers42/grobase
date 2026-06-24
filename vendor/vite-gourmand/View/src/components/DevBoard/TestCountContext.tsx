/**
 * TestCountContext - Provides test count across components
 * Used for dynamic sidebar badges
 */

import { createContext, useContext } from 'react';

interface TestCountContextValue {
  testCount: number;
}

const TestCountContext = createContext<TestCountContextValue>({ testCount: 0 });

export const TestCountProvider = TestCountContext.Provider;

export function useTestCount() {
  return useContext(TestCountContext);
}
