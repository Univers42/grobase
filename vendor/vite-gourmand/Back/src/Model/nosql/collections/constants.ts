/**
 * Collection Names - Constants
 * ============================
 * Single source of truth for collection names.
 */

export const COLLECTIONS = {
  MENU_ANALYTICS: 'menu_analytics',
  REVENUE_BY_MENU: 'revenue_by_menu',
  DASHBOARD_STATS: 'dashboard_stats',
  SEARCH_ANALYTICS: 'search_analytics',
  USER_ACTIVITY_LOGS: 'user_activity_logs',
  AUDIT_LOGS: 'audit_logs',
  ORDER_SNAPSHOTS: 'order_snapshots',
} as const;

export type CollectionName = (typeof COLLECTIONS)[keyof typeof COLLECTIONS];
