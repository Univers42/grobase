/**
 * MetricsDashboard - Grid of all metric widgets
 * Shows test results and performance metrics
 */

import { MetricWidget } from './MetricWidget';
import './MetricsDashboard.css';

interface MetricsDashboardProps {
  totalTests: number;
  passedTests: number;
  failedTests: number;
  passRate: number;
  isLoading?: boolean;
}

export function MetricsDashboard({
  totalTests,
  passedTests,
  failedTests,
  passRate,
  isLoading = false,
}: Readonly<MetricsDashboardProps>) {
  if (isLoading) {
    return (
      <section className="metrics-dashboard metrics-dashboard--loading">
        <div className="metrics-loading">
          <div className="metrics-loading__animation">
            <svg viewBox="0 0 100 100" className="metrics-loading__svg">
              {/* Outer rotating ring */}
              <circle
                cx="50"
                cy="50"
                r="45"
                fill="none"
                stroke="var(--color-border, #e5e7eb)"
                strokeWidth="2"
              />
              <circle
                cx="50"
                cy="50"
                r="45"
                fill="none"
                stroke="var(--color-primary, #722F37)"
                strokeWidth="3"
                strokeLinecap="round"
                strokeDasharray="70 200"
                className="metrics-loading__ring"
              />

              {/* Inner geometric shapes */}
              <g className="metrics-loading__shapes">
                {/* Triangle */}
                <polygon
                  points="50,25 60,42 40,42"
                  fill="var(--color-primary, #722F37)"
                  className="metrics-loading__triangle"
                />
                {/* Square */}
                <rect
                  x="42"
                  y="48"
                  width="16"
                  height="16"
                  fill="var(--color-success, #059669)"
                  className="metrics-loading__square"
                />
                {/* Circle */}
                <circle
                  cx="50"
                  cy="75"
                  r="6"
                  fill="var(--color-warning, #d97706)"
                  className="metrics-loading__dot"
                />
              </g>

              {/* Orbiting dots */}
              <g className="metrics-loading__orbit">
                <circle cx="50" cy="12" r="4" fill="var(--color-primary, #722F37)" />
              </g>
              <g className="metrics-loading__orbit metrics-loading__orbit--delayed">
                <circle cx="50" cy="12" r="3" fill="var(--color-success, #059669)" />
              </g>
            </svg>
          </div>
          <div className="metrics-loading__text">
            <span className="metrics-loading__title">Running Tests...</span>
            <span className="metrics-loading__subtitle">
              Please wait while tests are being executed
            </span>
          </div>
        </div>
        <div className="metrics-dashboard__skeleton">
          {[1, 2, 3, 4].map((i) => (
            <div key={i} className="metric-widget metric-widget--skeleton">
              <div className="metric-widget__skeleton-label" />
              <div className="metric-widget__skeleton-value" />
            </div>
          ))}
        </div>
      </section>
    );
  }

  const passRateTrend = getPassRateTrend(passRate);

  return (
    <section className="metrics-dashboard">
      <MetricWidget label="Total Tests" value={totalTests} trend="stable" />
      <MetricWidget
        label="Passed"
        value={passedTests}
        trend={passedTests > 0 ? 'down' : 'stable'}
      />
      <MetricWidget label="Failed" value={failedTests} trend={failedTests > 0 ? 'up' : 'stable'} />
      <MetricWidget
        label="Pass Rate"
        value={passRate}
        unit="%"
        trend={passRateTrend}
      />
    </section>
  );
}

function getPassRateTrend(passRate: number): 'up' | 'down' | 'stable' {
  if (passRate >= 90) return 'down';
  if (passRate >= 70) return 'stable';
  return 'up';
}
