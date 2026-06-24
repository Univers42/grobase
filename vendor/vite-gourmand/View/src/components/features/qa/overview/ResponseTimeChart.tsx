/**
 * ResponseTimeChart - Bar chart showing response time distribution
 * Simulated data for visual demonstration
 */

import { useMemo } from 'react';
import './ResponseTimeChart.css';

interface ResponseTimeChartProps {
  avgTime: number;
  totalTime: number;
}

export function ResponseTimeChart({ avgTime, totalTime }: Readonly<ResponseTimeChartProps>) {
  // Generate mock time distribution data

  const timeData = useMemo(() => {
    const ranges = [
      { label: '0-50ms', min: 0, max: 50 },
      { label: '50-100ms', min: 50, max: 100 },
      { label: '100-200ms', min: 100, max: 200 },
      { label: '200-500ms', min: 200, max: 500 },
      { label: '500ms+', min: 500, max: 1000 },
    ];

    // Simulate distribution based on average (deterministic)
    return ranges.map((range, i) => {
      let count;
      if (avgTime < range.min) {
        count = Math.max(0, 3 - Math.floor((range.min - avgTime) / 50));
      } else if (avgTime <= range.max) {
        count = 4 + (i % 3); // deterministic variation instead of Math.random()
      } else {
        count = Math.max(0, 5 - Math.floor((avgTime - range.max) / 100));
      }
      return { ...range, count };
    });
  }, [avgTime]);

  const maxCount = Math.max(...timeData.map((d) => d.count), 1);

  return (
    <div className="response-time-chart">
      <h4 className="response-time-chart-title">Response Time Distribution</h4>

      <div className="response-time-chart-container">
        <div className="response-time-bars">
          {timeData.map((item, index) => (
            <div key={item.label} className="response-time-bar-group">
              <div
                className="response-time-bar"
                style={{
                  height: `${(item.count / maxCount) * 100}%`,
                  animationDelay: `${index * 100}ms`,
                }}
              >
                <span className="response-time-bar-value">{item.count}</span>
              </div>
              <span className="response-time-bar-label">{item.label}</span>
            </div>
          ))}
        </div>

        <div className="response-time-stats">
          <div className="response-time-stat">
            <span className="response-time-stat-value">{Math.round(avgTime)}ms</span>
            <span className="response-time-stat-label">Average</span>
          </div>
          <div className="response-time-stat">
            <span className="response-time-stat-value">{totalTime}ms</span>
            <span className="response-time-stat-label">Total</span>
          </div>
        </div>
      </div>
    </div>
  );
}
