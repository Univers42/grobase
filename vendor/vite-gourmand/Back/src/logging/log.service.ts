/**
 * Log Service - In-memory log storage for DevBoard streaming
 * Stores recent HTTP request logs for live monitoring
 */
import { Injectable } from '@nestjs/common';

export interface StructuredLog {
  timestamp: string;
  level: 'info' | 'warn' | 'error' | 'debug';
  source: string;
  message: string;
  meta?: Record<string, unknown>;
}

const MAX_LOGS = 500;

@Injectable()
export class LogService {
  private logs: StructuredLog[] = [];

  /**
   * Add a log entry
   */
  addLog(log: StructuredLog): void {
    this.logs.push(log);
    // Keep only last MAX_LOGS entries
    if (this.logs.length > MAX_LOGS) {
      this.logs = this.logs.slice(-MAX_LOGS);
    }
  }

  /**
   * Log an HTTP request
   */
  logHttp(
    method: string,
    url: string,
    statusCode: number,
    duration: number,
    ip: string,
    error?: string,
  ): void {
    const level = this.getHttpLogLevel(statusCode);
    const source = this.getHttpLogSource(url);

    const errorMessage = error ? `: ${error}` : '';

    this.addLog({
      timestamp: new Date().toISOString(),
      level,
      source,
      message: `${method} ${url} ${statusCode} - ${duration}ms [${ip}]${errorMessage}`,
      meta: {
        method,
        path: url,
        statusCode,
        duration,
        ip,
        error,
      },
    });
  }

  private getHttpLogLevel(statusCode: number): StructuredLog['level'] {
    if (statusCode >= 500) return 'error';
    if (statusCode >= 400) return 'warn';
    return 'info';
  }

  private getHttpLogSource(url: string): StructuredLog['source'] {
    if (url.includes('/auth')) return 'auth';
    if (url.includes('/api')) return 'api';
    return 'http';
  }

  /**
   * Get recent logs with optional filtering
   */
  getLogs(options?: {
    limit?: number;
    level?: string;
    source?: string;
    since?: string;
  }): StructuredLog[] {
    let result = [...this.logs];

    // Filter by level
    if (options?.level) {
      result = result.filter((log) => log.level === options.level);
    }

    // Filter by source
    if (options?.source) {
      result = result.filter((log) => log.source === options.source);
    }

    // Filter by timestamp
    if (options?.since) {
      const sinceDate = new Date(options.since);
      result = result.filter((log) => new Date(log.timestamp) > sinceDate);
    }

    // Apply limit
    const limit = options?.limit || 100;
    return result.slice(-limit);
  }

  /**
   * Clear all logs
   */
  clear(): void {
    this.logs = [];
  }

  /**
   * Get log count
   */
  getCount(): number {
    return this.logs.length;
  }
}
