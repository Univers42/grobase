/**
 * User Activity Service
 * =====================
 * Tracks user actions for behavior analysis.
 * TTL: 30 days (low long-term value)
 */

import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import type { UserActivityLog } from '../types';

type ActionType = UserActivityLog['action'];
type TargetType = UserActivityLog['targetType'];

async function getCollection() {
  const db = await getDb();
  return db.collection<UserActivityLog>(COLLECTIONS.USER_ACTIVITY_LOGS);
}

/**
 * Log a user action
 */
export async function logActivity(
  userId: number,
  sessionId: string,
  action: ActionType,
  targetType: TargetType,
  options?: {
    targetId?: number;
    targetName?: string;
    searchContext?: { query: string; filters: Record<string, unknown> };
    ipAddress?: string;
    userAgent?: string;
  },
): Promise<void> {
  const collection = await getCollection();

  await collection.insertOne({
    userId,
    sessionId,
    action,
    targetType,
    targetId: options?.targetId,
    targetName: options?.targetName,
    searchContext: options?.searchContext,
    ipAddress: options?.ipAddress,
    userAgent: options?.userAgent,
    timestamp: new Date(),
  });
}

/**
 * Log menu view
 */
export async function logMenuView(
  userId: number,
  sessionId: string,
  menuId: number,
  menuTitle: string,
): Promise<void> {
  await logActivity(userId, sessionId, 'view_menu', 'menu', {
    targetId: menuId,
    targetName: menuTitle,
  });
}

/**
 * Log search action
 */
export async function logSearch(
  userId: number,
  sessionId: string,
  query: string,
  filters: Record<string, unknown>,
): Promise<void> {
  await logActivity(userId, sessionId, 'search', 'page', {
    searchContext: { query, filters },
  });
}

/**
 * Log order placement
 */
export async function logOrderPlaced(
  userId: number,
  sessionId: string,
  orderId: number,
  orderNumber: string,
): Promise<void> {
  await logActivity(userId, sessionId, 'place_order', 'order', {
    targetId: orderId,
    targetName: orderNumber,
  });
}

/**
 * Get user activity history
 */
export async function getUserActivity(
  userId: number,
  limit = 50,
): Promise<UserActivityLog[]> {
  const collection = await getCollection();
  return collection
    .find({ userId })
    .sort({ timestamp: -1 })
    .limit(limit)
    .toArray();
}

/**
 * Get session activity
 */
export async function getSessionActivity(
  sessionId: string,
): Promise<UserActivityLog[]> {
  const collection = await getCollection();
  return collection.find({ sessionId }).sort({ timestamp: 1 }).toArray();
}

/**
 * Get recent activity by action type
 */
export async function getActivityByAction(
  action: ActionType,
  limit = 100,
): Promise<UserActivityLog[]> {
  const collection = await getCollection();
  return collection
    .find({ action })
    .sort({ timestamp: -1 })
    .limit(limit)
    .toArray();
}

export const UserActivityService = {
  logActivity,
  logMenuView,
  logSearch,
  logOrderPlaced,
  getUserActivity,
  getSessionActivity,
  getActivityByAction,
};
