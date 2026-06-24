/**
 * ManualTestPage - Full page for executing a manual test
 * Shows instructions, actions, and results
 */

import type { ManualTest } from './types';
import { TestInstructions } from './TestInstructions';
import { TestActions } from './TestActions';
import './ManualTestPage.css';

interface ManualTestPageProps {
  test: ManualTest;
  notes?: string;
  onNotesChange?: (notes: string) => void;
  onPass?: () => void;
  onFail?: () => void;
  onBlock?: () => void;
  onBack?: () => void;
}

export function ManualTestPage({
  test,
  notes,
  onNotesChange,
  onPass,
  onFail,
  onBlock,
  onBack,
}: Readonly<ManualTestPageProps>) {
  const isCompleted = test.result !== 'pending';

  return (
    <div className="manual-test-page">
      <header className="manual-test-page-header">
        <button className="manual-test-page-back" onClick={onBack}>
          ← Back to list
        </button>
        <h1 className="manual-test-page-title">{test.title}</h1>
        <p className="manual-test-page-description">{test.description}</p>
      </header>

      <section className="manual-test-page-content">
        <h2 className="manual-test-page-section-title">Test Steps</h2>
        <TestInstructions steps={test.steps} />
      </section>

      <section className="manual-test-page-actions">
        <h2 className="manual-test-page-section-title">Record Result</h2>
        <TestActions
          notes={notes}
          onNotesChange={onNotesChange}
          onPass={onPass}
          onFail={onFail}
          onBlock={onBlock}
          disabled={isCompleted}
        />
      </section>
    </div>
  );
}
