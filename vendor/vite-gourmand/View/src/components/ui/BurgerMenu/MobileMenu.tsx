/**
 * MobileMenu - Slide-out menu for mobile navigation
 */

import type { NavSection } from '../../layout/Header/Header';
import type { CategoryData, TestCategory } from '../../features/qa/sidebar';
import { useMobileMenu } from './useMobileMenu';
import './MobileMenu.css';

interface MobileMenuProps {
  isOpen: boolean;
  onClose: () => void;
  navItems: NavItem[];
  categories: CategoryData[];
  activeSection: NavSection;
  activeCategory: TestCategory;
  onNavChange: (section: NavSection) => void;
  onCategoryChange: (category: TestCategory) => void;
}

interface NavItem {
  id: NavSection;
  label: string;
  icon: React.ReactNode;
}

export function MobileMenu(props: Readonly<MobileMenuProps>) {
  const {
    isOpen,
    onClose,
    navItems,
    categories,
    activeSection,
    activeCategory,
    onNavChange,
    onCategoryChange,
  } = props;
  useMobileMenu(isOpen, onClose);

  if (!isOpen) return null;

  return (
    <dialog className="mobile-menu-overlay" onCancel={onClose} aria-label="Mobile navigation" open>
      <nav className="mobile-menu">
        <NavSection items={navItems} active={activeSection} onSelect={onNavChange} />
        <hr className="mobile-menu-divider" />
        <CategorySection
          categories={categories}
          active={activeCategory}
          onSelect={(c) => {
            onCategoryChange(c);
            onClose();
          }}
        />
      </nav>
    </dialog>
  );
}

function NavSection<T extends string>({
  items,
  active,
  onSelect,
}: Readonly<{
  items: { id: T; label: string; icon: React.ReactNode }[];
  active: T;
  onSelect: (id: T) => void;
}>) {
  return (
    <div className="mobile-menu-section">
      <h3 className="mobile-menu-title">Navigation</h3>
      {items.map((item) => (
        <button
          key={item.id}
          className={`mobile-menu-item ${active === item.id ? 'mobile-menu-item--active' : ''}`}
          onClick={() => onSelect(item.id)}
        >
          <span className="mobile-menu-icon">{item.icon}</span>
          <span>{item.label}</span>
        </button>
      ))}
    </div>
  );
}

function CategorySection({
  categories,
  active,
  onSelect,
}: Readonly<{
  categories: CategoryData[];
  active: TestCategory;
  onSelect: (cat: TestCategory) => void;
}>) {
  const main = categories.filter((c) => c.group === 'main');
  const utility = categories.filter((c) => c.group === 'utility');

  return (
    <div className="mobile-menu-section">
      <h3 className="mobile-menu-title">Categories</h3>
      {main.map((c) => (
        <CatBtn key={c.id} cat={c} active={active} onSelect={onSelect} />
      ))}
      {utility.length > 0 && <hr className="mobile-menu-divider" />}
      {utility.map((c) => (
        <CatBtn key={c.id} cat={c} active={active} onSelect={onSelect} />
      ))}
    </div>
  );
}

function CatBtn({
  cat,
  active,
  onSelect,
}: Readonly<{
  cat: CategoryData;
  active: TestCategory;
  onSelect: (c: TestCategory) => void;
}>) {
  return (
    <button
      className={`mobile-menu-item ${active === cat.id ? 'mobile-menu-item--active' : ''}`}
      onClick={() => onSelect(cat.id)}
    >
      <span className="mobile-menu-label">{cat.label}</span>
      {cat.count !== undefined && <span className="mobile-menu-badge">{cat.count}</span>}
    </button>
  );
}
