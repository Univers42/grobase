/**
 * Index Definitions
 * =================
 * MongoDB indexes for all analytics collections.
 * TTL indexes handle automatic data expiration.
 */

import { IndexDescription } from 'mongodb';
import { COLLECTIONS } from './constants';

// TTL in seconds
const TTL_30_DAYS = 30 * 24 * 60 * 60;
const TTL_90_DAYS = 90 * 24 * 60 * 60;
const TTL_180_DAYS = 180 * 24 * 60 * 60;

export interface CollectionIndexes {
  collection: string;
  indexes: IndexDescription[];
}

export const INDEX_DEFINITIONS: CollectionIndexes[] = [
  {
    collection: COLLECTIONS.MENU_ANALYTICS,
    indexes: [
      { key: { menuId: 1, period: 1 }, unique: true },
      { key: { periodType: 1, period: -1 } },
    ],
  },
  {
    collection: COLLECTIONS.REVENUE_BY_MENU,
    indexes: [
      { key: { menuId: 1, period: 1 }, unique: true },
      { key: { periodType: 1, period: -1 } },
    ],
  },
  {
    collection: COLLECTIONS.DASHBOARD_STATS,
    indexes: [{ key: { date: 1, type: 1 }, unique: true }],
  },
  {
    collection: COLLECTIONS.SEARCH_ANALYTICS,
    indexes: [
      { key: { normalizedQuery: 1 } },
      { key: { timestamp: -1 } },
      { key: { timestamp: 1 }, expireAfterSeconds: TTL_30_DAYS },
    ],
  },
  {
    collection: COLLECTIONS.USER_ACTIVITY_LOGS,
    indexes: [
      { key: { userId: 1, timestamp: -1 } },
      { key: { sessionId: 1 } },
      { key: { action: 1, timestamp: -1 } },
      { key: { timestamp: 1 }, expireAfterSeconds: TTL_30_DAYS },
    ],
  },
  {
    collection: COLLECTIONS.AUDIT_LOGS,
    indexes: [
      { key: { entityType: 1, entityId: 1 } },
      { key: { userId: 1, timestamp: -1 } },
      { key: { timestamp: 1 }, expireAfterSeconds: TTL_90_DAYS },
    ],
  },
  {
    collection: COLLECTIONS.ORDER_SNAPSHOTS,
    indexes: [
      { key: { orderId: 1 }, unique: true },
      { key: { 'user.id': 1 } },
      { key: { orderDate: -1 } },
      { key: { status: 1 } },
      { key: { createdAt: 1 }, expireAfterSeconds: TTL_180_DAYS },
    ],
  },
];
