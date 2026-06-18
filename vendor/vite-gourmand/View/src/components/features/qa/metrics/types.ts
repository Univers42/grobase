/**
 * Metrics types
 */

export type MetricTrend = 'up' | 'down' | 'stable';

export interface MetricData {
  id: string;
  label: string;
  value: number;
  unit: string;
  trend: MetricTrend;
  change?: number;
}

export interface TimeSeriesPoint {
  timestamp: Date;
  value: number;
}
