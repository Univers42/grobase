/**
 * TestCardGrid - Grid container for test cards
 * Responsive layout for test card items
 */

import type { TestItem } from './types';
import { TestCardItem } from './TestCardItem';
import './TestCardGrid.css';

interface TestCardGridProps {
  tests: TestItem[];
  onRunTest?: (id: string) => void;
  onViewTest?: (id: string) => void;
}

export function TestCardGrid({ tests, onRunTest, onViewTest }: Readonly<TestCardGridProps>) {
  if (tests.length === 0) {
    return (
      <div className="test-card-grid-empty">
        <p>No tests found</p>
      </div>
    );
  }

  return (
    <div className="test-card-grid">
      {tests.map((test) => (
        <TestCardItem
          key={test.id}
          test={test}
          onRun={onRunTest ? () => onRunTest(test.id) : undefined}
          onView={onViewTest ? () => onViewTest(test.id) : undefined}
        />
      ))}
    </div>
  );
}
