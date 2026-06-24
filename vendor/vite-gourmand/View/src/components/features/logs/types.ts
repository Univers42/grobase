export interface DevLogEntry {
  timestamp: string;
  level: 'info' | 'warn' | 'error' | 'debug';
  source: string;
  message: string;
  meta?: Record<string, unknown>;
}
