/**
 * QA Sidebar types
 * Fly.io-inspired category structure
 */

/** Category identifiers - Fly.io style organization */
export type TestCategory =
  | 'overview'
  | 'test-automatics'
  | 'scenarios'
  | 'database'
  | 'settings'
  | 'logs'
  | 'metrics'
  | 'activity';

/** Category group type */
export type CategoryGroup = 'main' | 'utility';

/** Category definition with metadata */
export interface CategoryData {
  id: TestCategory;
  label: string;
  icon: string;
  count?: number;
  group: CategoryGroup;
  description?: string;
}
