/**
 * RunAllButton - Button to run all automatic tests
 * Shows count and loading state
 */

import { PrimaryButton } from '../../../ui/buttons/PrimaryButton';
import { Spinner } from '../../../ui/loaders/Spinner';
import './RunAllButton.css';

interface RunAllButtonProps {
  count?: number;
  isRunning?: boolean;
  onRun?: () => void;
}

export function RunAllButton({ count, isRunning, onRun }: Readonly<RunAllButtonProps>) {
  // Show count only if we have results, otherwise just "Run All"
  const label = count && count > 0 ? `▶ Run All (${count})` : '▶ Run All Tests';

  return (
    <div className="run-all-button">
      <PrimaryButton onClick={onRun} disabled={isRunning}>
        {isRunning ? (
          <>
            <Spinner size="sm" />
            <span>Running...</span>
          </>
        ) : (
          <span>{label}</span>
        )}
      </PrimaryButton>
    </div>
  );
}
