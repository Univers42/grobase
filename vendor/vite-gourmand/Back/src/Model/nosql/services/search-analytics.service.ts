/**
 * Search Analytics Service
 * ========================
 * Tracks search queries and conversion rates.
 * TTL: 30 days (regenerable data)
 */

import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import type { SearchAnalytics } from '../types';

async function getCollection() {
  const db = await getDb();
  return db.collection<SearchAnalytics>(COLLECTIONS.SEARCH_ANALYTICS);
}

/**
 * Log a search query
 */
export async function logSearch(
  query: string,
  resultsCount: number,
  sessionId: string,
  options?: {
    userId?: number;
    filters?: {
      diet?: string;
      theme?: string;
      priceRange?: { min: number; max: number };
    };
  },
): Promise<string> {
  const collection = await getCollection();

  const doc: SearchAnalytics = {
    query,
    normalizedQuery: normalizeQuery(query),
    resultsCount,
    clickedResults: [],
    filters: options?.filters || {},
    userId: options?.userId,
    sessionId,
    convertedToOrder: false,
    timestamp: new Date(),
  };

  const result = await collection.insertOne(doc);
  return result.insertedId.toString();
}

/**
 * Track a click on search result
 */
export async function trackClick(
  sessionId: string,
  query: string,
  menuId: number,
): Promise<void> {
  const collection = await getCollection();
  const normalized = normalizeQuery(query);

  await collection.updateOne(
    { sessionId, normalizedQuery: normalized },
    { $addToSet: { clickedResults: menuId } },
  );
}

/**
 * Mark search as converted to order
 */
export async function markConverted(sessionId: string): Promise<void> {
  const collection = await getCollection();

  // Mark all recent searches from this session as converted
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);

  await collection.updateMany(
    { sessionId, timestamp: { $gte: oneHourAgo } },
    { $set: { convertedToOrder: true } },
  );
}

/**
 * Get top search queries
 */
export async function getTopQueries(
  limit = 20,
): Promise<Array<{ query: string; count: number }>> {
  const collection = await getCollection();

  return collection
    .aggregate<{
      query: string;
      count: number;
    }>([
      { $group: { _id: '$normalizedQuery', count: { $sum: 1 } } },
      { $sort: { count: -1 } },
      { $limit: limit },
      { $project: { _id: 0, query: '$_id', count: 1 } },
    ])
    .toArray();
}

/**
 * Get queries with no results
 */
export async function getNoResultQueries(
  limit = 20,
): Promise<Array<{ query: string; count: number }>> {
  const collection = await getCollection();

  return collection
    .aggregate<{
      query: string;
      count: number;
    }>([
      { $match: { resultsCount: 0 } },
      { $group: { _id: '$normalizedQuery', count: { $sum: 1 } } },
      { $sort: { count: -1 } },
      { $limit: limit },
      { $project: { _id: 0, query: '$_id', count: 1 } },
    ])
    .toArray();
}

/**
 * Get search conversion rate
 */
export async function getConversionRate(): Promise<{
  total: number;
  converted: number;
  rate: number;
}> {
  const collection = await getCollection();

  const [stats] = await collection
    .aggregate<{ total: number; converted: number }>([
      {
        $group: {
          _id: null,
          total: { $sum: 1 },
          converted: { $sum: { $cond: ['$convertedToOrder', 1, 0] } },
        },
      },
    ])
    .toArray();

  const total = stats?.total || 0;
  const converted = stats?.converted || 0;
  const rate = total > 0 ? (converted / total) * 100 : 0;

  return { total, converted, rate };
}

/**
 * Normalize search query for grouping
 */
function normalizeQuery(query: string): string {
  return query.toLowerCase().trim().replace(/\s+/g, ' ');
}

export const SearchAnalyticsService = {
  logSearch,
  trackClick,
  markConverted,
  getTopQueries,
  getNoResultQueries,
  getConversionRate,
};
