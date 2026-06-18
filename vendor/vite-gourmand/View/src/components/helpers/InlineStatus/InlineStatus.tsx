/**
 * InlineStatus - Compact inline status indicator
 * Used for showing status in tables and lists
 */

import './InlineStatus.css';

type StatusType = 'success' | 'error' | 'warning' | 'info' | 'neutral';

interface InlineStatusProps {
  type: StatusType;
  text: string;
  showIcon?: boolean;
}

const STATUS_ICONS: Record<StatusType, string> = {
  success: '✓',
  error: '✕',
  warning: '!',
  info: 'i',
  neutral: '○',
};

export function InlineStatus({ type, text, showIcon = true }: Readonly<InlineStatusProps>) {
  const classes = buildClasses(type);

  return (
    <span className={classes}>
      {showIcon && <InlineStatusIcon type={type} />}
      <span className="inline-status-text">{text}</span>
    </span>
  );
}

function buildClasses(type: StatusType): string {
  return ['inline-status', `inline-status-${type}`].join(' ');
}

function InlineStatusIcon({ type }: Readonly<{ type: StatusType }>) {
  return (
    <span className="inline-status-icon" aria-hidden="true">
      {STATUS_ICONS[type]}
    </span>
  );
}
