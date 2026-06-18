/**
 * Menu Analytics Service
 * ======================
 * Tracks menu views, orders, and performance.
 */

import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import type { MenuAnalytics } from '../types';

/**
 * Get the analytics collection
 */
async function getCollection() {
  const db = await getDb();
  return db.collection<MenuAnalytics>(COLLECTIONS.MENU_ANALYTICS);
}

/**
 * Increment view count for a menu
 */
export async function incrementViewCount(
  menuId: number,
  menuTitle: string,
  periodType: MenuAnalytics['periodType'] = 'daily',
): Promise<void> {
  const collection = await getCollection();
  const period = getCurrentPeriod(periodType);

  await collection.updateOne(
    { menuId, period, periodType },
    {
      $inc: { viewCount: 1 },
      $set: { menuTitle, updatedAt: new Date() },
      $setOnInsert: { createdAt: new Date(), orderCount: 0, totalRevenue: 0 },
    },
    { upsert: true },
  );
}

/**
 * Increment order count and revenue
 */
export async function recordOrder(
  menuId: number,
  menuTitle: string,
  revenue: number,
  diet?: string,
  theme?: string,
): Promise<void> {
  const collection = await getCollection();
  const period = getCurrentPeriod('daily');
  const hour = new Date().getHours();

  const update: Record<string, Record<string, unknown>> = {
    $inc: { orderCount: 1, totalRevenue: revenue },
    $set: { menuTitle, updatedAt: new Date() },
    $addToSet: { peakHours: hour },
  };

  if (diet) update.$inc[`ordersByDiet.${diet}`] = 1;
  if (theme) update.$inc[`ordersByTheme.${theme}`] = 1;

  await collection.updateOne({ menuId, period, periodType: 'daily' }, update, {
    upsert: true,
  });
}

/**
 * Update average rating for a menu
 */
export async function updateRating(
  menuId: number,
  rating: number,
): Promise<void> {
  const collection = await getCollection();
  const period = getCurrentPeriod('monthly');

  const doc = await collection.findOne({
    menuId,
    period,
    periodType: 'monthly',
  });
  const currentCount = doc?.ratingCount || 0;
  const currentAvg = doc?.averageRating || 0;
  const newCount = currentCount + 1;
  const newAvg = (currentAvg * currentCount + rating) / newCount;

  await collection.updateOne(
    { menuId, period, periodType: 'monthly' },
    {
      $set: {
        averageRating: newAvg,
        ratingCount: newCount,
        updatedAt: new Date(),
      },
    },
    { upsert: true },
  );
}

/**
 * Get top menus by order count
 */
export async function getTopMenus(
  periodType: 'daily' | 'weekly' | 'monthly',
  limit = 10,
): Promise<MenuAnalytics[]> {
  const collection = await getCollection();
  const period = getCurrentPeriod(periodType);

  return collection
    .find({ periodType, period })
    .sort({ orderCount: -1 })
    .limit(limit)
    .toArray();
}

/**
 * Get current period string based on type
 */
function getCurrentPeriod(type: 'daily' | 'weekly' | 'monthly'): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');

  if (type === 'daily') return `${year}-${month}-${day}`;
  if (type === 'monthly') return `${year}-${month}`;
  // Weekly: use ISO week
  const week = getISOWeek(now);
  return `${year}-W${String(week).padStart(2, '0')}`;
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

export const MenuAnalyticsService = {
  incrementViewCount,
  recordOrder,
  updateRating,
  getTopMenus,
};
