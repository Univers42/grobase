/**
 * DevBoardHeader - Top navigation with 4 main sections
 * Dashboard, Docs, Resources, Account
 */

import { Header, type NavSection } from '../layout/Header/Header';
import type { CategoryData, TestCategory } from '../features/qa/sidebar';

interface DevBoardHeaderProps {
  activeSection?: NavSection;
  onSectionChange?: (section: NavSection) => void;
  categories?: CategoryData[];
  activeCategory?: TestCategory;
  onCategoryChange?: (category: TestCategory) => void;
}

export function DevBoardHeader({
  activeSection = 'dashboard',
  onSectionChange,
  categories,
  activeCategory,
  onCategoryChange,
}: Readonly<DevBoardHeaderProps>) {
  return (
    <Header
      activeSection={activeSection}
      onSectionChange={onSectionChange}
      categories={categories}
      activeCategory={activeCategory}
      onCategoryChange={onCategoryChange}
    />
  );
}
