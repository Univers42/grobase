// nav-items.ts — the single source of the dashboard navigation. Sidebar (and any
// future mobile nav) render from this list so routes/labels stay in one place.

import type { IconName } from '../ds/Icon';

/** NavItem is one sidebar entry: path, label, and icon. */
export type NavItem = { to: string; label: string; icon: IconName; end?: boolean };

/** navItems is the ordered dashboard navigation. */
export const navItems: readonly NavItem[] = [
  { to: '/app', label: 'Overview', icon: 'dashboard', end: true },
  { to: '/app/users', label: 'Users', icon: 'users' },
  { to: '/app/inbox', label: 'Inbox', icon: 'inbox' },
  { to: '/app/revenue', label: 'Revenue', icon: 'revenue' },
  { to: '/app/content', label: 'Content', icon: 'content' },
];
