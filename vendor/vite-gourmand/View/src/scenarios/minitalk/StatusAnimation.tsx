/**
 * Animated Status Badge - Simple and reliable status display
 */

import type { OrderStatus } from '../../services/orders';

interface StatusAnimationProps {
  status: OrderStatus;
  isAnimating?: boolean;
  size?: 'sm' | 'md' | 'lg';
}

const statusConfig: Record<
  string,
  { color: string; bgColor: string; label: string; emoji: string }
> = {
  pending: { color: '#f59e0b', bgColor: '#fef3c7', label: 'En attente', emoji: '⏳' },
  confirmed: { color: '#3b82f6', bgColor: '#dbeafe', label: 'Confirmé', emoji: '✓' },
  preparing: { color: '#3b82f6', bgColor: '#dbeafe', label: 'Préparation', emoji: '👨‍🍳' },
  cooking: { color: '#ef4444', bgColor: '#fee2e2', label: 'Cuisson', emoji: '🔥' },
  assembling: { color: '#8b5cf6', bgColor: '#ede9fe', label: 'Assemblage', emoji: '📦' },
  ready: { color: '#10b981', bgColor: '#d1fae5', label: 'Prêt !', emoji: '✅' },
  delivery: { color: '#f97316', bgColor: '#ffedd5', label: 'En livraison', emoji: '🚗' },
  delivered: { color: '#10b981', bgColor: '#d1fae5', label: 'Livré', emoji: '✅' },
  cancelled: { color: '#dc2626', bgColor: '#fee2e2', label: 'Annulé', emoji: '❌' },
};

const sizeConfig = {
  sm: { box: 48, font: '1.25rem', labelSize: '0.65rem' },
  md: { box: 72, font: '2rem', labelSize: '0.75rem' },
  lg: { box: 96, font: '2.5rem', labelSize: '0.875rem' },
};

export function StatusAnimation({
  status,
  isAnimating = false,
  size = 'md',
}: StatusAnimationProps) {
  const config = statusConfig[status] || statusConfig.pending;
  const sizes = sizeConfig[size];

  const containerStyle: React.CSSProperties = {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: '0.5rem',
  };

  const circleStyle: React.CSSProperties = {
    width: sizes.box,
    height: sizes.box,
    borderRadius: '50%',
    backgroundColor: config.bgColor,
    border: '3px solid ' + config.color,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    fontSize: sizes.font,
    animation: isAnimating ? 'statusPulse 0.6s ease-in-out infinite' : 'none',
    boxShadow: isAnimating ? '0 0 20px ' + config.color + '40' : 'none',
    transition: 'all 0.3s ease',
  };

  const labelStyle: React.CSSProperties = {
    fontSize: sizes.labelSize,
    fontWeight: 600,
    padding: '0.25rem 0.5rem',
    borderRadius: '9999px',
    backgroundColor: config.bgColor,
    color: config.color,
    animation: isAnimating ? 'statusPulse 0.6s ease-in-out infinite' : 'none',
  };

  return (
    <div style={containerStyle}>
      <div style={circleStyle}>{config.emoji}</div>
      <span style={labelStyle}>{config.label}</span>
    </div>
  );
}
