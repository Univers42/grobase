/**
 * Skeleton - Placeholder loading state
 * Used for content loading placeholders
 */

import './Skeleton.css';

interface SkeletonProps {
  variant?: 'text' | 'circular' | 'rectangular';
  width?: string;
  height?: string;
  lines?: number;
}

export function Skeleton({ variant = 'text', width, height, lines = 1 }: Readonly<SkeletonProps>) {
  const style = buildStyle(width, height);

  if (variant === 'text' && lines > 1) {
    return <SkeletonLines count={lines} />;
  }

  return <div className={`skeleton skeleton-${variant}`} style={style} />;
}

function buildStyle(width?: string, height?: string): React.CSSProperties {
  return {
    ...(width && { width }),
    ...(height && { height }),
  };
}

function SkeletonLines({ count }: Readonly<{ count: number }>) {
  return (
    <div className="skeleton-lines">
      {Array.from({ length: count }, (_, i) => (
        <div
          key={i}
          className="skeleton skeleton-text"
          style={{ width: i === count - 1 ? '60%' : '100%' }}
        />
      ))}
    </div>
  );
}
