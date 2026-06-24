/**
 * Activity Types
 * Type definitions for activity monitoring
 */

export type ActivityType =
  | 'order' // Orders placed, updated, cancelled
  | 'user' // User logins, registrations
  | 'menu' // Menu item changes
  | 'system' // System events (deploys, restarts)
  | 'staff' // Staff actions
  | 'alert'; // Alerts and warnings

export type ActivitySeverity = 'info' | 'success' | 'warning' | 'error';

export interface Activity {
  id: string;
  type: ActivityType;
  severity: ActivitySeverity;
  title: string;
  description: string;
  timestamp: Date;
  user?: string;
  metadata?: Record<string, unknown>;
}

export interface ActivityFilter {
  types: ActivityType[];
  severity?: ActivitySeverity;
  dateRange?: { start: Date; end: Date };
}
