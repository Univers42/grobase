/**
 * Dashboard Stats Service
 * =======================
 * Pre-computed statistics for admin dashboard.
 * TTL: 365 days (year-over-year comparison)
 */

import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import type { DashboardStats } from '../types';

type StatsType = DashboardStats['type'];

async function getCollection() {
  const db = await getDb();
  return db.collection<DashboardStats>(COLLECTIONS.DASHBOARD_STATS);
}

/**
 * Update or create dashboard stats for a date
 */
export async function updateStats(
  date: string,
  type: StatsType,
  stats: Partial<Omit<DashboardStats, '_id' | 'date' | 'type' | 'computedAt'>>,
): Promise<void> {
  const collection = await getCollection();

  await collection.updateOne(
    { date, type },
    { $set: { ...stats, computedAt: new Date() } },
    { upsert: true },
  );
}

/**
 * Increment order counters
 */
export async function incrementOrderCount(
  status: 'total' | 'completed' | 'cancelled' | 'pending',
  revenue?: number,
): Promise<void> {
  const collection = await getCollection();
  const date = getTodayString();

  const inc: Record<string, number> = { totalOrders: 1 };
  if (status === 'completed') inc.completedOrders = 1;
  if (status === 'cancelled') inc.cancelledOrders = 1;
  if (status === 'pending') inc.pendingOrders = 1;
  if (revenue) inc.totalRevenue = revenue;

  await collection.updateOne(
    { date, type: 'daily' },
    { $inc: inc, $set: { computedAt: new Date() } },
    { upsert: true },
  );
}

/**
 * Increment user counters
 */
export async function incrementUserCount(
  type: 'new' | 'active' | 'returning',
): Promise<void> {
  const collection = await getCollection();
  const date = getTodayString();

  const fields = {
    new: 'newUsers',
    active: 'activeUsers',
    returning: 'returningUsers',
  } as const;
  const field = fields[type];

  await collection.updateOne(
    { date, type: 'daily' },
    { $inc: { [field]: 1 }, $set: { computedAt: new Date() } },
    { upsert: true },
  );
}

/**
 * Get stats for a specific date
 */
export async function getStats(
  date: string,
  type: StatsType = 'daily',
): Promise<DashboardStats | null> {
  const collection = await getCollection();
  return collection.findOne({ date, type });
}

/**
 * Get stats for a date range
 */
export async function getStatsRange(
  startDate: string,
  endDate: string,
  type: StatsType = 'daily',
): Promise<DashboardStats[]> {
  const collection = await getCollection();
  return collection
    .find({ type, date: { $gte: startDate, $lte: endDate } })
    .sort({ date: 1 })
    .toArray();
}

/**
 * Get latest stats
 */
export async function getLatestStats(
  type: StatsType = 'daily',
): Promise<DashboardStats | null> {
  const collection = await getCollection();
  const results = await collection
    .find({ type })
    .sort({ date: -1 })
    .limit(1)
    .toArray();
  return results[0] || null;
}

/**
 * Compute and store weekly/monthly aggregates
 */
export async function aggregateStats(
  sourceType: 'daily',
  targetType: 'weekly' | 'monthly',
): Promise<void> {
  const db = await getDb();
  const collection = db.collection<DashboardStats>(COLLECTIONS.DASHBOARD_STATS);

  const period = targetType === 'weekly' ? getCurrentWeek() : getCurrentMonth();
  const startDate = targetType === 'weekly' ? getWeekStart() : getMonthStart();

  const pipeline = [
    { $match: { type: sourceType, date: { $gte: startDate } } },
    {
      $group: {
        _id: null,
        totalOrders: { $sum: '$totalOrders' },
        completedOrders: { $sum: '$completedOrders' },
        cancelledOrders: { $sum: '$cancelledOrders' },
        totalRevenue: { $sum: '$totalRevenue' },
        newUsers: { $sum: '$newUsers' },
        activeUsers: { $sum: '$activeUsers' },
      },
    },
  ];

  const [result] = await collection.aggregate(pipeline).toArray();
  if (result) {
    delete result._id;
    await updateStats(period, targetType, result);
  }
}

function getTodayString(): string {
  return new Date().toISOString().split('T')[0];
}

function getCurrentMonth(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

function getCurrentWeek(): string {
  const now = new Date();
  const week = getISOWeek(now);
  return `${now.getFullYear()}-W${String(week).padStart(2, '0')}`;
}

function getMonthStart(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-01`;
}

function getWeekStart(): string {
  const now = new Date();
  const day = now.getDay() || 7;
  now.setDate(now.getDate() - day + 1);
  return now.toISOString().split('T')[0];
}

function getISOWeek(date: Date): number {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7));
  const week1 = new Date(d.getFullYear(), 0, 4);
  return (
    1 +
    Math.round(
      ((d.getTime() - week1.getTime()) / 86400000 -
        3 +
        ((week1.getDay() + 6) % 7)) /
        7,
    )
  );
}

export const DashboardStatsService = {
  updateStats,
  incrementOrderCount,
  incrementUserCount,
  getStats,
  getStatsRange,
  getLatestStats,
  aggregateStats,
};
