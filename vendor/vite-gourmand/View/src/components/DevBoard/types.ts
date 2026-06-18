/**
 * DevBoard types
 */

import type { TestCategory } from '../features/qa/sidebar';

export type ViewMode = 'grid' | 'list';

export interface DevBoardState {
  activeCategory: TestCategory;
  viewMode: ViewMode;
  isSidebarCollapsed: boolean;
}
