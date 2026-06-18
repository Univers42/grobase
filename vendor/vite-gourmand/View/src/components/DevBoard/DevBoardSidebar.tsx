/**
 * DevBoardSidebar - Navigation sidebar
 * Category list with collapse functionality
 */

import { Sidebar, RoleSwitcher } from '../layout/Sidebar';
import { SidebarHeader, CategoryList } from '../features/qa/sidebar';
import type { TestCategory, CategoryData } from '../features/qa/sidebar';

interface DevBoardSidebarProps {
  categories: CategoryData[];
  activeCategory: TestCategory;
  collapsed: boolean;
  onSelectCategory: (category: TestCategory) => void;
  onToggleCollapse: () => void;
}

export function DevBoardSidebar({
  categories,
  activeCategory,
  collapsed,
  onSelectCategory,
  onToggleCollapse,
}: Readonly<DevBoardSidebarProps>) {
  return (
    <Sidebar collapsed={collapsed}>
      <SidebarHeader collapsed={collapsed} onToggle={onToggleCollapse} />
      <CategoryList
        categories={categories}
        activeCategory={activeCategory}
        collapsed={collapsed}
        onSelect={onSelectCategory}
      />
      <RoleSwitcher collapsed={collapsed} />
    </Sidebar>
  );
}
