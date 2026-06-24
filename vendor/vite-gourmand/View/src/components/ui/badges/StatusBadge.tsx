/**
 * StatusBadge - Displays test/task status
 * Used for showing idle, running, success, failed states
 */

import { CheckIcon, XIcon, CircleIcon, RefreshIcon } from '../../icons/FlyIcons';
import './StatusBadge.css';

export type BadgeStatus = 'idle' | 'running' | 'success' | 'failed' | 'pending' | 'passed';

interface StatusBadgeProps {
  status: BadgeStatus;
  size?: 'sm' | 'md';
}

const STATUS_CONFIG: Record<
  BadgeStatus,
  { label: string; Icon: React.ComponentType<{ size?: number; className?: string }> }
> = {
  idle: { label: 'En attente', Icon: CircleIcon },
  running: { label: 'En cours', Icon: RefreshIcon },
  success: { label: 'Réussi', Icon: CheckIcon },
  passed: { label: 'Réussi', Icon: CheckIcon },
  failed: { label: 'Échoué', Icon: XIcon },
  pending: { label: 'En suspens', Icon: CircleIcon },
};

export function StatusBadge({ status, size = 'md' }: Readonly<StatusBadgeProps>) {
  const config = STATUS_CONFIG[status];
  const classes = buildClasses(status, size);
  const iconSize = size === 'sm' ? 10 : 12;

  return (
    <output className={classes} aria-live="polite">
      <span className="status-badge-icon" aria-hidden="true">
        <config.Icon size={iconSize} />
      </span>
      <span className="status-badge-label">{config.label}</span>
    </output>
  );
}

function buildClasses(status: BadgeStatus, size: string): string {
  // Map 'passed' to 'success' for CSS class
  const cssStatus = status === 'passed' ? 'success' : status;
  return ['status-badge', `status-badge-${cssStatus}`, `status-badge-${size}`].join(' ');
}
