// Sidebar.tsx — the fixed glass navigation rail. Renders NavLinks from nav-items;
// the active route gets aria-current and the accent treatment.

import { NavLink } from 'react-router-dom';
import clsx from 'clsx';
import { navItems } from './nav-items';
import { Icon } from '../ds/Icon';

/** linkClass styles a nav link by its active state. */
function linkClass({ isActive }: { isActive: boolean }): string {
  return clsx(
    'flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition',
    isActive ? 'bg-accent-soft text-ink ring-1 ring-accent/25' : 'text-muted hover:bg-white/5 hover:text-ink',
  );
}

/** Sidebar renders the brand mark and the primary navigation. */
export function Sidebar() {
  return (
    <aside className="glass hidden h-full flex-col gap-6 rounded-2xl p-4 md:flex">
      <div className="flex items-center gap-2.5 px-2 pt-2">
        <span className="grid size-9 place-items-center rounded-xl bg-gradient-to-br from-accent to-cyan text-accent-fg">
          <Icon name="zap" size={18} />
        </span>
        <span className="text-lg font-semibold tracking-tight text-ink">Nimbus</span>
      </div>
      <nav aria-label="Primary" className="flex flex-1 flex-col gap-1">
        {navItems.map((item) => (
          <NavLink key={item.to} to={item.to} end={item.end} className={linkClass}>
            {({ isActive }) => (
              <span className="flex items-center gap-3" aria-current={isActive ? 'page' : undefined}>
                <Icon name={item.icon} size={18} />
                {item.label}
              </span>
            )}
          </NavLink>
        ))}
      </nav>
      <div className="rounded-xl border border-line bg-surface-2/60 p-3 text-xs text-muted">
        <p className="font-medium text-ink/80">Workspace</p>
        <p className="mt-0.5">Nimbus · production</p>
      </div>
    </aside>
  );
}
