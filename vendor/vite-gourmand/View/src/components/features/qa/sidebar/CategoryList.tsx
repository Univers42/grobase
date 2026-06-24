/**
 * CategoryList - Navigation list of test categories
 * Fly.io-style with section dividers
 */

import type { CategoryData, TestCategory } from './types';
import { CategoryItem } from './CategoryItem';
import './CategoryList.css';

interface CategoryListProps {
  categories: CategoryData[];
  activeCategory: TestCategory;
  collapsed?: boolean;
  onSelect: (category: TestCategory) => void;
}

export function CategoryList({
  categories,
  activeCategory,
  collapsed,
  onSelect,
}: Readonly<CategoryListProps>) {
  // Group categories by their group property
  const mainCategories = categories.filter((c) => c.group === 'main');
  const utilityCategories = categories.filter((c) => c.group === 'utility');

  return (
    <nav className="category-list" aria-label="Test categories">
      {/* Main section */}
      <div className="category-section">
        {mainCategories.map((category) => (
          <CategoryItem
            key={category.id}
            category={category}
            isActive={activeCategory === category.id}
            collapsed={collapsed}
            onClick={() => onSelect(category.id)}
          />
        ))}
      </div>

      {/* Divider */}
      {!collapsed && utilityCategories.length > 0 && <hr className="category-divider" />}

      {/* Utility section */}
      <div className="category-section">
        {utilityCategories.map((category) => (
          <CategoryItem
            key={category.id}
            category={category}
            isActive={activeCategory === category.id}
            collapsed={collapsed}
            onClick={() => onSelect(category.id)}
          />
        ))}
      </div>
    </nav>
  );
}
