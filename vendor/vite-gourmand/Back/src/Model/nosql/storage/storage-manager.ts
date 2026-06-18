/**
 * Storage Manager
 * ===============
 * Monitors MongoDB Atlas storage and performs cleanup.
 * Respects retention policies and priority order.
 */

import { Db } from 'mongodb';
import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS, CollectionName } from '../collections';
import { RETENTION_RULES, getCleanupOrder } from './retention-policy';
import type { StorageInfo, CollectionStats } from '../types';

// Default thresholds from .env or fallback
const MAX_STORAGE_MB = Number.parseInt(
  process.env.MONGODB_MAX_STORAGE_MB || '450',
  10,
);
const CLEANUP_THRESHOLD = Number.parseInt(
  process.env.MONGODB_CLEANUP_THRESHOLD_PERCENT || '85',
  10,
);

/**
 * Get storage statistics for all collections
 */
export async function getStorageStats(): Promise<StorageInfo> {
  const db = await getDb();
  const dbStats = (await db.stats()) as { dataSize?: number };
  const totalSizeMB = (dbStats.dataSize ?? 0) / (1024 * 1024);

  const collections: CollectionStats[] = [];
  for (const name of Object.values(COLLECTIONS)) {
    const collStats = await getCollectionStats(db, name);
    collections.push(collStats);
  }

  return {
    totalSizeMB,
    maxStorageMB: MAX_STORAGE_MB,
    usedPercent: (totalSizeMB / MAX_STORAGE_MB) * 100,
    collections: collections.toSorted((a, b) => b.sizeMB - a.sizeMB),
  };
}

interface MongoStats {
  count?: number;
  size?: number;
  avgObjSize?: number;
}

/**
 * Get stats for a single collection
 */
async function getCollectionStats(
  db: Db,
  name: string,
): Promise<CollectionStats> {
  try {
    const stats = (await db.command({ collStats: name })) as MongoStats;
    return {
      name,
      count: stats.count ?? 0,
      sizeMB: (stats.size ?? 0) / (1024 * 1024),
      avgDocSizeKB: (stats.avgObjSize ?? 0) / 1024,
    };
  } catch {
    return { name, count: 0, sizeMB: 0, avgDocSizeKB: 0 };
  }
}

/**
 * Check if cleanup is needed
 */
export async function needsCleanup(): Promise<boolean> {
  const stats = await getStorageStats();
  return stats.usedPercent >= CLEANUP_THRESHOLD;
}

/**
 * Run cleanup based on priority and retention
 */
export async function runCleanup(emergency = false): Promise<number> {
  const db = await getDb();
  const order = getCleanupOrder();
  let totalDeleted = 0;

  for (const collName of order) {
    const rule = RETENTION_RULES.find((r) => r.collection === collName);
    if (!rule) continue;

    const ttlDays = emergency ? Math.floor(rule.ttlDays / 2) : rule.ttlDays;
    const deleted = await cleanupCollection(db, collName, ttlDays);
    totalDeleted += deleted;

    const stillNeeds = await needsCleanup();
    if (!stillNeeds) break;
  }

  return totalDeleted;
}

/**
 * Delete old documents from a collection
 */
async function cleanupCollection(
  db: Db,
  name: CollectionName,
  ttlDays: number,
): Promise<number> {
  const cutoffDate = new Date();
  cutoffDate.setDate(cutoffDate.getDate() - ttlDays);

  const dateField = getDateField(name);
  const result = await db.collection(name).deleteMany({
    [dateField]: { $lt: cutoffDate },
  });

  console.log(
    `[Cleanup] ${name}: deleted ${result.deletedCount} docs older than ${ttlDays} days`,
  );
  return result.deletedCount;
}

/**
 * Get the date field used for TTL in each collection
 */
function getDateField(name: CollectionName): string {
  const fields: Record<CollectionName, string> = {
    [COLLECTIONS.USER_ACTIVITY_LOGS]: 'timestamp',
    [COLLECTIONS.SEARCH_ANALYTICS]: 'timestamp',
    [COLLECTIONS.AUDIT_LOGS]: 'timestamp',
    [COLLECTIONS.ORDER_SNAPSHOTS]: 'createdAt',
    [COLLECTIONS.MENU_ANALYTICS]: 'createdAt',
    [COLLECTIONS.REVENUE_BY_MENU]: 'createdAt',
    [COLLECTIONS.DASHBOARD_STATS]: 'computedAt',
  };
  return fields[name] || 'createdAt';
}

export const StorageManager = {
  getStats: getStorageStats,
  needsCleanup,
  runCleanup,
};
