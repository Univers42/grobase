/**
 * TestActions - Pass/Fail buttons with notes
 * Actions for manual test results
 */

import { SuccessButton } from '../../../ui/buttons/SuccessButton';
import { DangerButton } from '../../../ui/buttons/DangerButton';
import { SecondaryButton } from '../../../ui/buttons/SecondaryButton';
import { TextArea } from '../../../ui/inputs/TextArea';
import './TestActions.css';

interface TestActionsProps {
  notes?: string;
  onNotesChange?: (notes: string) => void;
  onPass?: () => void;
  onFail?: () => void;
  onBlock?: () => void;
  disabled?: boolean;
}

export function TestActions({
  notes = '',
  onNotesChange,
  onPass,
  onFail,
  onBlock,
  disabled,
}: Readonly<TestActionsProps>) {
  return (
    <div className="test-actions">
      <TextArea
        id="test-notes"
        name="notes"
        value={notes}
        onChange={(value) => onNotesChange?.(value)}
        placeholder="Add notes about the test result..."
        rows={3}
        disabled={disabled}
      />
      <div className="test-actions-buttons">
        <SuccessButton onClick={onPass} disabled={disabled}>
          ✓ Pass
        </SuccessButton>
        <DangerButton onClick={onFail} disabled={disabled}>
          ✗ Fail
        </DangerButton>
        <SecondaryButton onClick={onBlock} disabled={disabled}>
          ⊘ Blocked
        </SecondaryButton>
      </div>
    </div>
  );
}
