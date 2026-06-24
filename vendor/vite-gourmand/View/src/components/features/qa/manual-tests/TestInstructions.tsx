/**
 * TestInstructions - List of test steps
 * Displays each step with instruction and expected result
 */

import type { ManualTestStep } from './types';
import './TestInstructions.css';

interface TestInstructionsProps {
  steps: ManualTestStep[];
}

export function TestInstructions({ steps }: Readonly<TestInstructionsProps>) {
  return (
    <ol className="test-instructions">
      {steps.map((step, index) => (
        <li key={step.id} className="test-instructions-step">
          <div className="test-instructions-number">{index + 1}</div>
          <div className="test-instructions-content">
            <p className="test-instructions-action">{step.instruction}</p>
            <p className="test-instructions-expected">
              <strong>Expected:</strong> {step.expected}
            </p>
          </div>
        </li>
      ))}
    </ol>
  );
}
