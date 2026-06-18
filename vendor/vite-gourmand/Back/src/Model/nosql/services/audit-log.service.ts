/**
 * Audit Log Service
 * =================
 * Compliance logging for data changes.
 * TTL: 90 days (compliance requirement)
 */

import { getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import type { AuditLog } from '../types';

type AuditAction = AuditLog['action'];

async function getCollection() {
  const db = await getDb();
  return db.collection<AuditLog>(COLLECTIONS.AUDIT_LOGS);
}

/**
 * Log an audit event
 */
export async function log(
  action: AuditAction,
  entityType: string,
  options?: {
    userId?: number;
    userEmail?: string;
    userRole?: string;
    entityId?: number;
    previousState?: Record<string, unknown>;
    newState?: Record<string, unknown>;
    changedFields?: string[];
    ipAddress?: string;
    userAgent?: string;
  },
): Promise<void> {
  const collection = await getCollection();

  await collection.insertOne({
    action,
    entityType,
    userId: options?.userId,
    userEmail: options?.userEmail,
    userRole: options?.userRole,
    entityId: options?.entityId,
    previousState: options?.previousState,
    newState: options?.newState,
    changedFields: options?.changedFields,
    ipAddress: options?.ipAddress,
    userAgent: options?.userAgent,
    timestamp: new Date(),
  });
}

/**
 * Log entity creation
 */
export async function logCreate(
  entityType: string,
  entityId: number,
  newState: Record<string, unknown>,
  user?: { id: number; email: string; role: string },
): Promise<void> {
  await log('create', entityType, {
    entityId,
    newState,
    userId: user?.id,
    userEmail: user?.email,
    userRole: user?.role,
  });
}

/**
 * Log entity update with diff
 */
export async function logUpdate(
  entityType: string,
  entityId: number,
  previousState: Record<string, unknown>,
  newState: Record<string, unknown>,
  user?: { id: number; email: string; role: string },
): Promise<void> {
  const changedFields = computeChangedFields(previousState, newState);

  await log('update', entityType, {
    entityId,
    previousState,
    newState,
    changedFields,
    userId: user?.id,
    userEmail: user?.email,
    userRole: user?.role,
  });
}

/**
 * Log entity deletion
 */
export async function logDelete(
  entityType: string,
  entityId: number,
  previousState: Record<string, unknown>,
  user?: { id: number; email: string; role: string },
): Promise<void> {
  await log('delete', entityType, {
    entityId,
    previousState,
    userId: user?.id,
    userEmail: user?.email,
    userRole: user?.role,
  });
}

/**
 * Log user login
 */
export async function logLogin(
  userId: number,
  email: string,
  ipAddress?: string,
  userAgent?: string,
): Promise<void> {
  await log('login', 'user', {
    userId,
    userEmail: email,
    ipAddress,
    userAgent,
  });
}

/**
 * Get audit logs for an entity
 */
export async function getEntityLogs(
  entityType: string,
  entityId: number,
): Promise<AuditLog[]> {
  const collection = await getCollection();
  return collection
    .find({ entityType, entityId })
    .sort({ timestamp: -1 })
    .toArray();
}

/**
 * Get audit logs for a user
 */
export async function getUserLogs(
  userId: number,
  limit = 100,
): Promise<AuditLog[]> {
  const collection = await getCollection();
  return collection
    .find({ userId })
    .sort({ timestamp: -1 })
    .limit(limit)
    .toArray();
}

/**
 * Compute which fields changed between two states
 */
function computeChangedFields(
  prev: Record<string, unknown>,
  next: Record<string, unknown>,
): string[] {
  const allKeys = new Set([...Object.keys(prev), ...Object.keys(next)]);
  const changed: string[] = [];

  for (const key of allKeys) {
    if (JSON.stringify(prev[key]) !== JSON.stringify(next[key])) {
      changed.push(key);
    }
  }

  return changed;
}

export const AuditLogService = {
  log,
  logCreate,
  logUpdate,
  logDelete,
  logLogin,
  getEntityLogs,
  getUserLogs,
};
