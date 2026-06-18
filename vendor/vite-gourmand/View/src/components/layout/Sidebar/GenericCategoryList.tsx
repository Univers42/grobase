/**
 * GenericCategoryList - Reusable category list
 * Works with any category type that has id, label, icon
 */

import type { GenericCategory } from './types';
import './GenericCategoryList.css';

interface GenericCategoryListProps<T extends string> {
  categories: GenericCategory[];
  activeCategory: T;
  collapsed?: boolean;
  onSelect: (category: T) => void;
}

export function GenericCategoryList<T extends string>({
  categories,
  activeCategory,
  collapsed,
  onSelect,
}: Readonly<GenericCategoryListProps<T>>) {
  return (
    <nav className="generic-category-list" aria-label="Navigation">
      {categories.map((category) => (
        <CategoryItem
          key={category.id}
          category={category}
          isActive={activeCategory === category.id}
          collapsed={collapsed}
          onClick={() => onSelect(category.id as T)}
        />
      ))}
    </nav>
  );
}

interface CategoryItemProps {
  category: GenericCategory;
  isActive: boolean;
  collapsed?: boolean;
  onClick: () => void;
}

function CategoryItem({ category, isActive, collapsed, onClick }: Readonly<CategoryItemProps>) {
  const classes = buildClasses(isActive, collapsed);

  return (
    <button className={classes} onClick={onClick} title={category.label}>
      <span className="cat-icon">{category.icon}</span>
      {!collapsed && (
        <>
          <span className="cat-label">{category.label}</span>
          {category.count !== undefined && <span className="cat-count">{category.count}</span>}
        </>
      )}
    </button>
  );
}

function buildClasses(isActive: boolean, collapsed?: boolean): string {
  const classes = ['generic-category-item'];
  if (isActive) classes.push('active');
  if (collapsed) classes.push('collapsed');
  return classes.join(' ');
}
