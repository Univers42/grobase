/**
 * Retention Policy Configuration
 * ==============================
 * Defines data retention rules and cleanup priorities.
 * Used by StorageManager for automatic cleanup.
 */

import { COLLECTIONS, CollectionName } from '../collections';

export interface RetentionRule {
  collection: CollectionName;
  ttlDays: number;
  priority: number; // Lower = delete first
  description: string;
}

/**
 * Retention rules ordered by deletion priority
 * Priority 1 = delete first, Priority 6 = delete last
 */
export const RETENTION_RULES: RetentionRule[] = [
  {
    collection: COLLECTIONS.USER_ACTIVITY_LOGS,
    ttlDays: 30,
    priority: 1,
    description: 'Session data, low long-term value',
  },
  {
    collection: COLLECTIONS.SEARCH_ANALYTICS,
    ttlDays: 30,
    priority: 2,
    description: 'Search patterns, regenerable',
  },
  {
    collection: COLLECTIONS.AUDIT_LOGS,
    ttlDays: 90,
    priority: 3,
    description: 'Compliance requirement',
  },
  {
    collection: COLLECTIONS.ORDER_SNAPSHOTS,
    ttlDays: 180,
    priority: 4,
    description: 'Historical reference',
  },
  {
    collection: COLLECTIONS.MENU_ANALYTICS,
    ttlDays: 365,
    priority: 5,
    description: 'Business intelligence',
  },
  {
    collection: COLLECTIONS.REVENUE_BY_MENU,
    ttlDays: 365,
    priority: 5,
    description: 'CA par menu - subject requirement',
  },
  {
    collection: COLLECTIONS.DASHBOARD_STATS,
    ttlDays: 365,
    priority: 6,
    description: 'Year-over-year comparison',
  },
];

/**
 * Get retention rule for a collection
 */
export function getRetentionRule(
  name: CollectionName,
): RetentionRule | undefined {
  return RETENTION_RULES.find((r) => r.collection === name);
}

/**
 * Get collections sorted by cleanup priority
 */
export function getCleanupOrder(): CollectionName[] {
  return [...RETENTION_RULES]
    .sort((a, b) => a.priority - b.priority)
    .map((r) => r.collection);
}

export const RetentionPolicy = {
  rules: RETENTION_RULES,
  getRule: getRetentionRule,
  getCleanupOrder,
};
