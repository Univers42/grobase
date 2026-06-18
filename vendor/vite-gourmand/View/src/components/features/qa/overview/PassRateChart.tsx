/**
 * PassRateChart - Donut chart showing pass/fail distribution
 * Pure CSS implementation - no external charting library
 */

import './PassRateChart.css';

interface PassRateChartProps {
  passed: number;
  failed: number;
  total: number;
}

export function PassRateChart({ passed, failed, total }: Readonly<PassRateChartProps>) {
  const hasData = total > 0;
  const passPercent = hasData ? Math.round((passed / total) * 100) : 0;

  // For donut chart CSS
  const circumference = 2 * Math.PI * 45; // radius = 45
  const passOffset = hasData ? circumference - (circumference * passPercent) / 100 : circumference;

  return (
    <div className="pass-rate-chart">
      <h4 className="pass-rate-chart-title">Test Results Distribution</h4>

      <div className="pass-rate-chart-container">
        <svg className="pass-rate-donut" viewBox="0 0 100 100">
          {/* Background circle */}
          <circle
            className="pass-rate-donut-bg"
            cx="50"
            cy="50"
            r="45"
            fill="none"
            strokeWidth="10"
          />
          {/* Pass percentage arc */}
          <circle
            className="pass-rate-donut-progress"
            cx="50"
            cy="50"
            r="45"
            fill="none"
            strokeWidth="10"
            strokeDasharray={circumference}
            strokeDashoffset={passOffset}
            transform="rotate(-90 50 50)"
          />
          {/* Center text */}
          <text x="50" y="46" textAnchor="middle" className="pass-rate-donut-value">
            {hasData ? `${passPercent}%` : '—'}
          </text>
          <text x="50" y="58" textAnchor="middle" className="pass-rate-donut-label">
            {hasData ? 'Pass Rate' : 'No Data'}
          </text>
        </svg>

        <div className="pass-rate-legend">
          <div className="pass-rate-legend-item">
            <span className="pass-rate-legend-color pass-rate-legend-color--passed" />
            <span className="pass-rate-legend-label">Passed</span>
            <span className="pass-rate-legend-value">{passed}</span>
          </div>
          <div className="pass-rate-legend-item">
            <span className="pass-rate-legend-color pass-rate-legend-color--failed" />
            <span className="pass-rate-legend-label">Failed</span>
            <span className="pass-rate-legend-value">{failed}</span>
          </div>
          <div className="pass-rate-legend-item pass-rate-legend-item--total">
            <span className="pass-rate-legend-label">Total</span>
            <span className="pass-rate-legend-value">{total}</span>
          </div>
        </div>
      </div>
    </div>
  );
}
