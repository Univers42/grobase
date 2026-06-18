/**
 * WidgetCard — Shared wrapper for all profile widgets
 * Provides consistent card chrome: icon, title, glass effect
 */

import type { ReactNode } from 'react';

interface WidgetCardProps {
  icon: string;
  title: string;
  children: ReactNode;
  className?: string;
  /** Span 2 columns on wide screens */
  wide?: boolean;
}

export function WidgetCard({ icon, title, children, className = '', wide }: Readonly<WidgetCardProps>) {
  return (
    <div className={`up-widget ${wide ? 'up-widget--wide' : ''} ${className}`}>
      <div className="up-widget-header">
        <span className="up-widget-icon">{icon}</span>
        <h3 className="up-widget-title">{title}</h3>
      </div>
      <div className="up-widget-body">{children}</div>
    </div>
  );
}
