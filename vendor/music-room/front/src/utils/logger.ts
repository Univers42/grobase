import { Platform } from 'react-native';

const isProduction = process.env.NODE_ENV === 'production';

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LogEntry {
  level: LogLevel;
  message: string;
  data?: unknown;
  timestamp: string;
}

const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

const minLevel: LogLevel = isProduction ? 'warn' : 'debug';

function shouldLog(level: LogLevel): boolean {
  return LOG_LEVELS[level] >= LOG_LEVELS[minLevel];
}

function formatMessage(level: LogLevel, message: string, data?: unknown): LogEntry {
  return {
    level,
    message,
    data,
    timestamp: new Date().toISOString(),
  };
}

export const logger = {
  debug(message: string, data?: unknown): void {
    if (!shouldLog('debug')) return;
    const entry = formatMessage('debug', message, data);
    if (Platform.OS === 'web') {
      console.debug(`[${entry.timestamp}] DEBUG: ${message}`, data || '');
    } else {
      console.log(`🔍 ${message}`, data || '');
    }
  },

  info(message: string, data?: unknown): void {
    if (!shouldLog('info')) return;
    const entry = formatMessage('info', message, data);
    if (Platform.OS === 'web') {
      console.info(`[${entry.timestamp}] INFO: ${message}`, data || '');
    } else {
      console.log(`ℹ️ ${message}`, data || '');
    }
  },

  warn(message: string, data?: unknown): void {
    if (!shouldLog('warn')) return;
    const entry = formatMessage('warn', message, data);
    console.warn(`[${entry.timestamp}] WARN: ${message}`, data || '');
  },

  error(message: string, error?: unknown): void {
    if (!shouldLog('error')) return;
    const entry = formatMessage('error', message, error);
    console.error(`[${entry.timestamp}] ERROR: ${message}`, error || '');

    // In production, could send to error tracking service
    if (isProduction && error instanceof Error) {
      // TODO: Send to Sentry or similar
    }
  },

  /**
   * Log API request/response for debugging
   */
  api(method: string, url: string, status?: number, duration?: number): void {
    if (!shouldLog('debug')) return;
    const statusStr = status ? ` → ${status}` : '';
    const durationStr = duration ? ` (${duration}ms)` : '';
    console.log(`🌐 ${method} ${url}${statusStr}${durationStr}`);
  },

  /**
   * Log navigation events
   */
  navigation(screen: string, params?: Record<string, unknown>): void {
    if (!shouldLog('debug')) return;
    console.log(`📱 Navigate: ${screen}`, params || '');
  },
};
