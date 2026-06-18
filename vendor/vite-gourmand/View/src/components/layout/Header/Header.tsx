/** Header - Top navigation bar with burger menu for mobile */

import { useState, useMemo } from 'react';
import { BurgerIcon, MobileMenu } from '../../ui/BurgerMenu';
import { LogoIcon, DashboardIcon, DocsIcon, ResourcesIcon, NotificationIcon } from './HeaderIcons';
import { ProfileDropdown } from './ProfileDropdown';
import { SearchBar } from '../../ui/Search';
import { useRoleView } from '../../DevBoard/RoleViewContext';
import type { CategoryData, TestCategory } from '../../features/qa/sidebar';
import './Header.css';

export type NavSection = 'dashboard' | 'docs' | 'resources' | 'account';
export interface NavItem {
  id: NavSection;
  label: string;
  icon: React.ReactNode;
}

interface HeaderProps {
  activeSection?: NavSection;
  onSectionChange?: (section: NavSection) => void;
  categories?: CategoryData[];
  activeCategory?: TestCategory;
  onCategoryChange?: (category: TestCategory) => void;
}

// eslint-disable-next-line react-refresh/only-export-components
export const NAV_ITEMS: NavItem[] = [
  { id: 'dashboard', label: 'Dashboard', icon: <DashboardIcon /> },
  { id: 'docs', label: 'Docs', icon: <DocsIcon /> },
  { id: 'resources', label: 'Resources', icon: <ResourcesIcon /> },
];

export function Header({
  activeSection = 'dashboard',
  onSectionChange,
  categories = [],
  activeCategory = 'overview',
  onCategoryChange,
}: Readonly<HeaderProps>) {
  const [menuOpen, setMenuOpen] = useState(false);
  const { currentView } = useRoleView();
  const isClient = currentView === 'client';

  // Client view: only show Dashboard tab, hide docs/resources/search
  const visibleNavItems = useMemo(
    () => (isClient ? NAV_ITEMS.filter((item) => item.id === 'dashboard') : NAV_ITEMS),
    [isClient],
  );

  return (
    <header className="layout-header">
      <div className="header-left">
        <div className="header-burger">
          <BurgerIcon isOpen={menuOpen} onClick={() => setMenuOpen((v) => !v)} />
        </div>
        <Brand isClient={isClient} />
      </div>

      <nav className="header-nav">
        {visibleNavItems.map((item) => (
          <NavButton
            key={item.id}
            item={item}
            active={activeSection === item.id}
            onClick={onSectionChange}
          />
        ))}
      </nav>

      {!isClient && (
        <div className="header-search">
          <SearchBar placeholder="Rechercher un utilisateur..." />
        </div>
      )}

      <div className="header-actions">
        <NotificationButton />
        <ProfileDropdown />
      </div>

      <MobileMenu
        isOpen={menuOpen}
        onClose={() => setMenuOpen(false)}
        navItems={visibleNavItems}
        categories={categories}
        activeSection={activeSection}
        activeCategory={activeCategory}
        onNavChange={(s) => {
          onSectionChange?.(s);
          setMenuOpen(false);
        }}
        onCategoryChange={(c) => {
          onCategoryChange?.(c);
          setMenuOpen(false);
        }}
      />
    </header>
  );
}

function Brand({ isClient }: Readonly<{ isClient?: boolean }>) {
  return (
    <div className="header-brand">
      <div className="header-logo">
        <LogoIcon />
      </div>
      <span className="header-title">{isClient ? 'Mon Espace' : 'DevBoard'}</span>
    </div>
  );
}

const NavButton = ({
  item,
  active,
  onClick,
}: {
  item: NavItem;
  active: boolean;
  onClick?: (s: NavSection) => void;
}) => (
  <button
    className={`header-nav-item ${active ? 'header-nav-item--active' : ''}`}
    onClick={() => onClick?.(item.id)}
  >
    <span className="header-nav-icon">{item.icon}</span>
    <span className="header-nav-label">{item.label}</span>
  </button>
);

const NotificationButton = () => (
  <button className="header-action-btn" aria-label="Notifications">
    <NotificationIcon />
  </button>
);
