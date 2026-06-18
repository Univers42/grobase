/**
 * Overview Component
 * Visual dashboard with charts and metrics - No test lists
 */

import { HealthStatus } from './HealthStatus';
import { PassRateChart } from './PassRateChart';
import { ResponseTimeChart } from './ResponseTimeChart';
import { SystemMetrics } from './SystemMetrics';
import './Overview.css';

interface OverviewProps {
  metrics: {
    total: number;
    passed: number;
    failed: number;
    passRate: number;
    duration: number;
    lastRun: Date | null;
  };
  isRunning?: boolean;
}

export function Overview({ metrics, isRunning }: Readonly<OverviewProps>) {
  // Derive health status (-1 means no data yet / tests pending)
  const health = getHealthStatus(metrics.passRate);

  return (
    <div className="overview">
      {/* Health Status Banner */}
      <HealthStatus status={health} passRate={metrics.passRate} testsRunning={isRunning} />

      {/* Charts Grid */}
      <div className="overview-charts">
        <PassRateChart passed={metrics.passed} failed={metrics.failed} total={metrics.total} />
        <ResponseTimeChart
          avgTime={metrics.duration / Math.max(metrics.total, 1)}
          totalTime={metrics.duration}
        />
      </div>

      {/* System Metrics */}
      <SystemMetrics
        testCount={metrics.total}
        passRate={metrics.passRate}
        avgDuration={Math.round(metrics.duration / Math.max(metrics.total, 1))}
        lastRun={metrics.lastRun}
      />
    </div>
  );
}

function getHealthStatus(passRate: number): 'healthy' | 'warning' | 'critical' {
  if (passRate < 0) return 'healthy';
  if (passRate >= 95) return 'healthy';
  if (passRate >= 80) return 'warning';
  return 'critical';
}
