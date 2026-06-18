/**
 * Sidebar - Left navigation panel
 * Used for main navigation categories
 */

import './Sidebar.css';

interface SidebarProps {
  children: React.ReactNode;
  collapsed?: boolean;
}

export function Sidebar({ children, collapsed = false }: Readonly<SidebarProps>) {
  const classes = buildClasses(collapsed);

  return <aside className={classes}>{children}</aside>;
}

function buildClasses(collapsed: boolean): string {
  const classes = ['layout-sidebar'];
  if (collapsed) classes.push('layout-sidebar-collapsed');
  return classes.join(' ');
}
