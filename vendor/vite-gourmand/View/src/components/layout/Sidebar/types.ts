/**
 * Generic Category Types
 * For admin and employee dashboards
 */

export interface GenericCategory {
  id: string;
  label: string;
  icon: string;
  count?: number;
  group?: 'main' | 'utility';
}
