/**
 * Order Snapshot Service
 * ======================
 * Denormalized order copies for fast reads.
 * TTL: 180 days (historical reference)
 */

import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import type { OrderSnapshot } from '../types';

async function getCollection() {
  const db = await getDb();
  return db.collection<OrderSnapshot>(COLLECTIONS.ORDER_SNAPSHOTS);
}

/**
 * Create order snapshot from PostgreSQL order
 */
export async function createSnapshot(order: {
  id: number;
  orderNumber: string;
  user: { id: number; email: string; firstName: string; city?: string };
  orderDate: Date;
  deliveryDate: Date;
  deliveryHour: string;
  personNumber: number;
  status: string;
  menuPrice: number;
  deliveryPrice: number;
  discountAmount: number;
  totalPrice: number;
  menus: Array<{
    id: number;
    title: string;
    price: number;
    diet?: string;
    dishes?: string[];
  }>;
  materialLending: boolean;
}): Promise<void> {
  const collection = await getCollection();
  const tags = computeTags(order);

  await collection.updateOne(
    { orderId: order.id },
    {
      $set: {
        orderId: order.id,
        orderNumber: order.orderNumber,
        user: order.user,
        orderDate: order.orderDate,
        deliveryDate: order.deliveryDate,
        deliveryHour: order.deliveryHour,
        personNumber: order.personNumber,
        status: order.status,
        menuPrice: order.menuPrice,
        deliveryPrice: order.deliveryPrice,
        discountAmount: order.discountAmount,
        totalPrice: order.totalPrice,
        menus: order.menus,
        materialLending: order.materialLending,
        tags,
        createdAt: new Date(),
      },
    },
    { upsert: true },
  );
}

/**
 * Update order status in snapshot
 */
export async function updateStatus(
  orderId: number,
  status: string,
): Promise<void> {
  const collection = await getCollection();
  await collection.updateOne({ orderId }, { $set: { status } });
}

/**
 * Get snapshot by order ID
 */
export async function getByOrderId(
  orderId: number,
): Promise<OrderSnapshot | null> {
  const collection = await getCollection();
  return collection.findOne({ orderId });
}

/**
 * Get snapshots by user ID
 */
export async function getByUserId(
  userId: number,
  limit = 50,
): Promise<OrderSnapshot[]> {
  const collection = await getCollection();
  return collection
    .find({ 'user.id': userId })
    .sort({ orderDate: -1 })
    .limit(limit)
    .toArray();
}

/**
 * Get recent orders
 */
export async function getRecentOrders(limit = 100): Promise<OrderSnapshot[]> {
  const collection = await getCollection();
  return collection.find({}).sort({ orderDate: -1 }).limit(limit).toArray();
}

/**
 * Get orders by status
 */
export async function getByStatus(
  status: string,
  limit = 100,
): Promise<OrderSnapshot[]> {
  const collection = await getCollection();
  return collection
    .find({ status })
    .sort({ orderDate: -1 })
    .limit(limit)
    .toArray();
}

/**
 * Get peak ordering hours
 */
export async function getPeakHours(): Promise<
  Array<{ hour: number; count: number }>
> {
  const db = await getDb();
  const collection = db.collection<OrderSnapshot>(COLLECTIONS.ORDER_SNAPSHOTS);

  return collection
    .aggregate<{
      hour: number;
      count: number;
    }>([
      { $group: { _id: { $hour: '$orderDate' }, count: { $sum: 1 } } },
      { $sort: { count: -1 } },
      { $project: { _id: 0, hour: '$_id', count: 1 } },
    ])
    .toArray();
}

/**
 * Compute tags for filtering
 */
function computeTags(order: {
  personNumber: number;
  totalPrice: number;
  deliveryDate: Date;
}): string[] {
  const tags: string[] = [];

  if (order.personNumber >= 10) tags.push('large_party');
  if (order.totalPrice >= 200) tags.push('vip');

  const day = order.deliveryDate.getDay();
  if (day === 0 || day === 6) tags.push('weekend');

  return tags;
}

export const OrderSnapshotService = {
  createSnapshot,
  updateStatus,
  getByOrderId,
  getByUserId,
  getRecentOrders,
  getByStatus,
  getPeakHours,
};
