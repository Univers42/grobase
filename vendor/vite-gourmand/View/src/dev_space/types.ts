/**
 * Dev Space Types
 * Developer dashboard uses DevBoard categories
 */

export type DevCategory = 'overview' | 'tests' | 'api' | 'database' | 'activity';

export interface DevCategoryItem {
  id: DevCategory;
  label: string;
  icon: string;
  count?: number;
}

export const DEV_CATEGORIES: DevCategoryItem[] = [
  { id: 'overview', label: 'Overview', icon: '📊' },
  { id: 'tests', label: 'Tests', icon: '🧪' },
  { id: 'api', label: 'API', icon: '🔌' },
  { id: 'database', label: 'Database', icon: '🗄️' },
  { id: 'activity', label: 'Activity', icon: '📈' },
];
