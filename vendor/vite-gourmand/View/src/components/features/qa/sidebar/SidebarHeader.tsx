/**
 * SidebarHeader - Branding area of QA sidebar
 * Displays logo and subtle collapse toggle
 */

import './SidebarHeader.css';

interface SidebarHeaderProps {
  collapsed?: boolean;
  onToggle?: () => void;
}

export function SidebarHeader({ collapsed = false, onToggle }: Readonly<SidebarHeaderProps>) {
  return (
    <div className="sidebar-header">
      <Logo collapsed={collapsed} />
      {onToggle && <CollapseToggle collapsed={collapsed} onClick={onToggle} />}
    </div>
  );
}

function Logo({ collapsed }: Readonly<{ collapsed: boolean }>) {
  return (
    <div className="sidebar-logo">
      <span className="sidebar-logo-icon">🧪</span>
      {!collapsed && <span className="sidebar-logo-text">DevBoard</span>}
    </div>
  );
}

function CollapseToggle({ collapsed, onClick }: Readonly<{ collapsed: boolean; onClick: () => void }>) {
  return (
    <button
      type="button"
      className={`sidebar-collapse-toggle ${collapsed ? 'sidebar-collapse-toggle--collapsed' : ''}`}
      onClick={onClick}
      aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
    >
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
        <path d="M15 18l-6-6 6-6" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </button>
  );
}
