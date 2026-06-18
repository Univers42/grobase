/**
 * HealthStatus - Application health banner
 * Shows overall system health with visual indicator
 */

import { CheckIcon, WarningIcon, XIcon } from '../../../icons/FlyIcons';
import './HealthStatus.css';

interface HealthStatusProps {
  status: 'healthy' | 'warning' | 'critical';
  passRate: number;
  testsRunning?: boolean;
}

const statusConfig = {
  healthy: {
    Icon: CheckIcon,
    label: 'All Systems Operational',
    description: 'All tests passing. Application is healthy.',
  },
  warning: {
    Icon: WarningIcon,
    label: 'Degraded Performance',
    description: 'Some tests failing. Review recommended.',
  },
  critical: {
    Icon: XIcon,
    label: 'Critical Issues Detected',
    description: 'Multiple tests failing. Immediate attention required.',
  },
};

export function HealthStatus({ status, passRate, testsRunning }: Readonly<HealthStatusProps>) {
  const config = statusConfig[status];

  return (
    <div className={`health-status health-status--${status}`}>
      <div className="health-status-indicator">
        <span className="health-status-icon">
          <config.Icon size={24} />
        </span>
        {testsRunning && <span className="health-status-pulse" />}
      </div>
      <div className="health-status-content">
        <h3 className="health-status-title">{config.label}</h3>
        <p className="health-status-description">
          {testsRunning ? 'Running tests...' : config.description}
        </p>
      </div>
      <div className="health-status-metric">
        <span className="health-status-value">{passRate < 0 ? '—' : `${passRate}%`}</span>
        <span className="health-status-label">Pass Rate</span>
      </div>
    </div>
  );
}
