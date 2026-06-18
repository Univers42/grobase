/**
 * MongoDB Analytics Module - Entry Point
 * =====================================
 * Exports all MongoDB services, schemas, and utilities.
 * This module handles analytics, logging, and metrics.
 */

// Core client and connection
export { MongoAnalytics } from './client/mongo-analytics.client';

// Collection schemas
export * from './collections';

// Services
export { MenuAnalyticsService } from './services/menu-analytics.service';
export { UserActivityService } from './services/user-activity.service';
export { AuditLogService } from './services/audit-log.service';
export { DashboardStatsService } from './services/dashboard-stats.service';
export { SearchAnalyticsService } from './services/search-analytics.service';
export { OrderSnapshotService } from './services/order-snapshot.service';
export { RevenueService } from './services/revenue.service';

// Storage management
export { StorageManager } from './storage/storage-manager';
export { RetentionPolicy } from './storage/retention-policy';

// Types
export * from './types';
