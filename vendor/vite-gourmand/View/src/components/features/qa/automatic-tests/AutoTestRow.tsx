/**
 * AutoTestRow - Single automatic test row
 * Clean table row with proper alignment
 */

import { useState } from 'react';
import type { AutoTest } from './types';
import { InlineStatus } from '../../../helpers/InlineStatus';
import './AutoTestRow.css';

interface AutoTestRowProps {
  test: AutoTest;
  isEven?: boolean;
}

export function AutoTestRow({ test, isEven }: Readonly<AutoTestRowProps>) {
  const [isExpanded, setIsExpanded] = useState(false);

  const statusMap = {
    idle: 'neutral',
    running: 'info',
    passed: 'success',
    failed: 'error',
    skipped: 'neutral',
  } as const;

  const hasDetails = test.output || test.error;

  const handleRowClick = () => {
    if (hasDetails) setIsExpanded(!isExpanded);
  };

  return (
    <>
      <tr
        className={`atr ${isEven ? 'atr--alt' : ''} ${hasDetails ? 'atr--clickable' : ''}`}
        onClick={handleRowClick}
      >
        <td className="atr__cell atr__cell--name">
          <span className={`atr__dot atr__dot--${test.status}`} />
          {hasDetails && (
            <span className={`atr__chevron ${isExpanded ? 'atr__chevron--open' : ''}`}>▶</span>
          )}
          <span className="atr__name" title={test.name}>
            {test.name}
          </span>
        </td>
        <td className="atr__cell atr__cell--suite">
          <span className="atr__badge">{test.suite}</span>
        </td>
        <td className="atr__cell atr__cell--status">
          <InlineStatus type={statusMap[test.status]} text={test.status} />
        </td>
        <td className="atr__cell atr__cell--duration">
          {test.duration ? `${test.duration}ms` : '-'}
        </td>
      </tr>
      {isExpanded && hasDetails && (
        <tr className="atr atr--detail">
          <td colSpan={4} className="atr__detail-cell">
            {test.error && (
              <div className="atr__output atr__output--error">
                <div className="atr__output-label">❌ Error</div>
                <pre className="atr__output-content">{test.error}</pre>
              </div>
            )}
            {test.output && (
              <div className="atr__output">
                <div className="atr__output-label">📟 Output</div>
                <pre className="atr__output-content">{test.output}</pre>
              </div>
            )}
          </td>
        </tr>
      )}
    </>
  );
}
