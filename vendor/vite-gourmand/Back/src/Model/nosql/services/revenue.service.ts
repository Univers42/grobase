/**
 * Revenue Service
 * ===============
 * Tracks revenue by menu (subject requirement: CA par menu)
 * TTL: 365 days (business intelligence)
 */

import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import type { RevenueByMenu } from '../types';

async function getCollection() {
  const db = await getDb();
  return db.collection<RevenueByMenu>(COLLECTIONS.REVENUE_BY_MENU);
}

/**
 * Record revenue for a menu
 */
export async function recordRevenue(
  menuId: number,
  menuTitle: string,
  orderValue: number,
  personCount: number,
  deliveryPrice: number,
  discountAmount: number,
): Promise<void> {
  const collection = await getCollection();
  const period = getCurrentMonth();

  await collection.updateOne(
    { menuId, period, periodType: 'monthly' },
    {
      $inc: {
        orderCount: 1,
        totalRevenue: orderValue,
        totalPersons: personCount,
        deliveryRevenue: deliveryPrice,
        discountTotal: discountAmount,
      },
      $set: { menuTitle, updatedAt: new Date() },
      $setOnInsert: { createdAt: new Date() },
    },
    { upsert: true },
  );

  // Update average order value
  await updateAverageOrderValue(menuId, period);
}

/**
 * Update average order value for a menu
 */
async function updateAverageOrderValue(
  menuId: number,
  period: string,
): Promise<void> {
  const collection = await getCollection();
  const doc = await collection.findOne({
    menuId,
    period,
    periodType: 'monthly',
  });

  if (doc && doc.orderCount > 0) {
    const avg = doc.totalRevenue / doc.orderCount;
    await collection.updateOne(
      { menuId, period, periodType: 'monthly' },
      { $set: { averageOrderValue: avg } },
    );
  }
}

/**
 * Get revenue by menu for a period
 */
export async function getRevenueByMenu(
  startPeriod: string,
  endPeriod: string,
): Promise<
  Array<{
    menuId: number;
    menuTitle: string;
    totalRevenue: number;
    orderCount: number;
  }>
> {
  const db = await getDb();
  const collection = db.collection<RevenueByMenu>(COLLECTIONS.REVENUE_BY_MENU);

  const result = await collection
    .aggregate<{
      menuId: number;
      menuTitle: string;
      totalRevenue: number;
      orderCount: number;
    }>([
      {
        $match: {
          periodType: 'monthly',
          period: { $gte: startPeriod, $lte: endPeriod },
        },
      },
      {
        $group: {
          _id: { menuId: '$menuId', menuTitle: '$menuTitle' },
          totalRevenue: { $sum: '$totalRevenue' },
          totalOrders: { $sum: '$orderCount' },
          totalPersons: { $sum: '$totalPersons' },
        },
      },
      { $sort: { totalRevenue: -1 } },
      {
        $project: {
          _id: 0,
          menuId: '$_id.menuId',
          menuTitle: '$_id.menuTitle',
          totalRevenue: 1,
          orderCount: '$totalOrders',
          totalPersons: 1,
        },
      },
    ])
    .toArray();

  return result;
}

/**
 * Get revenue trend for a specific menu
 */
export async function getMenuRevenueTrend(
  menuId: number,
  limit = 12,
): Promise<
  Array<{ period: string; totalRevenue: number; orderCount: number }>
> {
  const collection = await getCollection();

  return collection
    .find({ menuId, periodType: 'monthly' })
    .sort({ period: -1 })
    .limit(limit)
    .project<{ period: string; totalRevenue: number; orderCount: number }>({
      _id: 0,
      period: 1,
      totalRevenue: 1,
      orderCount: 1,
    })
    .toArray();
}

/**
 * Get top revenue menus for current month
 */
export async function getTopRevenueMenus(limit = 10): Promise<RevenueByMenu[]> {
  const collection = await getCollection();
  const period = getCurrentMonth();

  return collection
    .find({ periodType: 'monthly', period })
    .sort({ totalRevenue: -1 })
    .limit(limit)
    .toArray();
}

/**
 * Compare all menus for a period (bar chart data)
 */
export async function compareMenus(
  period: string,
): Promise<
  Array<{ menuTitle: string; orderCount: number; totalRevenue: number }>
> {
  const collection = await getCollection();

  return collection
    .find({ periodType: 'monthly', period })
    .project<{ menuTitle: string; orderCount: number; totalRevenue: number }>({
      _id: 0,
      menuTitle: 1,
      orderCount: 1,
      totalRevenue: 1,
    })
    .sort({ orderCount: -1 })
    .toArray();
}

function getCurrentMonth(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

export const RevenueService = {
  recordRevenue,
  getRevenueByMenu,
  getMenuRevenueTrend,
  getTopRevenueMenus,
  compareMenus,
};
