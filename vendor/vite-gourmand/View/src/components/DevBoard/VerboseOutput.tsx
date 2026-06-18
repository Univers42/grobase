/**
 * CLI Output Panel
 * Displays raw CLI output from test execution - always visible when there's output
 */
import './VerboseOutput.css';

interface VerboseOutputProps {
  output: string | null;
  isVisible?: boolean; // kept for compatibility but not used
}

export function VerboseOutput({ output }: Readonly<VerboseOutputProps>) {
  if (!output) return null;

  return (
    <div className="verbose-output">
      <div className="verbose-output__header">
        <span className="verbose-output__title">📟 Raw CLI Output</span>
        <span className="verbose-output__badge">REAL BACKEND OUTPUT</span>
      </div>
      <pre className="verbose-output__content">{output}</pre>
    </div>
  );
}
