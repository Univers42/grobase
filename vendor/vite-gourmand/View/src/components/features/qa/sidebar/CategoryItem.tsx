/**
 * CategoryItem - Single navigation item in sidebar
 * Fly.io-inspired design with SVG icons
 */

import type { CategoryData } from './types';
import {
  SettingsIcon,
  MetricsIcon,
  LogsIcon,
  OverviewIcon,
  ActivityIcon,
  TestsIcon,
  ScenariosIcon,
  DatabaseIcon,
} from '../../../icons/FlyIcons';
import './CategoryItem.css';

interface CategoryItemProps {
  category: CategoryData;
  isActive: boolean;
  collapsed?: boolean;
  onClick: () => void;
}

export function CategoryItem({
  category,
  isActive,
  collapsed = false,
  onClick,
}: Readonly<CategoryItemProps>) {
  const classes = buildClasses(isActive);

  return (
    <button type="button" className={classes} onClick={onClick} title={category.description}>
      <span className="category-icon-wrapper">
        <CategoryIcon iconType={category.icon} />
      </span>
      {!collapsed && <CategoryLabel label={category.label} />}
      {!collapsed && category.count !== undefined && category.count > 0 && (
        <CategoryCount count={category.count} />
      )}
    </button>
  );
}

function buildClasses(isActive: boolean): string {
  const classes = ['category-item'];
  if (isActive) classes.push('category-item-active');
  return classes.join(' ');
}

function CategoryIcon({ iconType }: Readonly<{ iconType: string }>) {
  const iconProps = { size: 18, className: 'category-svg-icon' };

  switch (iconType) {
    case 'settings':
      return <SettingsIcon {...iconProps} />;
    case 'metrics':
      return <MetricsIcon {...iconProps} />;
    case 'logs':
      return <LogsIcon {...iconProps} />;
    case 'overview':
      return <OverviewIcon {...iconProps} />;
    case 'activity':
      return <ActivityIcon {...iconProps} />;
    case 'tests':
      return <TestsIcon {...iconProps} />;
    case 'scenarios':
      return <ScenariosIcon {...iconProps} />;
    case 'database':
      return <DatabaseIcon {...iconProps} />;
    default:
      return <OverviewIcon {...iconProps} />;
  }
}

function CategoryLabel({ label }: Readonly<{ label: string }>) {
  return <span className="category-label">{label}</span>;
}

function CategoryCount({ count }: Readonly<{ count: number }>) {
  return <span className="category-count">{count}</span>;
}
