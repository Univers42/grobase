/**
 * AutoTestList - List of automatic tests
 * Fly.io-style table with proper semantic markup
 */

import type { AutoTest } from './types';
import { AutoTestRow } from './AutoTestRow';
import './AutoTestList.css';

interface AutoTestListProps {
  tests: AutoTest[];
}

export function AutoTestList({ tests }: Readonly<AutoTestListProps>) {
  // Show empty state when no tests available
  if (tests.length === 0) {
    return (
      <div className="atl">
        <div style={{ padding: '32px', textAlign: 'center' }}>
          <div style={{ fontSize: '3rem', marginBottom: '16px' }}>🧪</div>
          <h3
            style={{
              fontSize: '1.125rem',
              fontWeight: 600,
              marginBottom: '8px',
              color: '#1f2937',
            }}
          >
            No Test Results Yet
          </h3>
          <p
            style={{
              color: '#6b7280',
              marginBottom: '16px',
              maxWidth: '500px',
              margin: '0 auto',
            }}
          >
            Click the <strong>"Run All Tests"</strong> button above to execute your test suites.
            Results will appear here showing pass/fail status for each test.
          </p>
          <div
            style={{
              marginTop: '24px',
              padding: '16px',
              background: '#f9fafb',
              borderRadius: '8px',
              fontSize: '0.875rem',
              color: '#6b7280',
            }}
          >
            💡 Tests are executed on the backend and results are cached for quick viewing
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="atl">
      <div className="atl__wrapper">
        <table className="atl__table">
          <thead className="atl__head">
            <tr>
              <th className="atl__th atl__th--name">Test Name</th>
              <th className="atl__th atl__th--suite">Suite</th>
              <th className="atl__th atl__th--status">Status</th>
              <th className="atl__th atl__th--duration">Duration</th>
            </tr>
          </thead>
          <tbody>
            {tests.map((test, index) => (
              <AutoTestRow key={test.id} test={test} isEven={index % 2 === 1} />
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
