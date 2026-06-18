/**
 * Rate limiter configuration for different endpoint categories.
 */
import { ThrottlerModuleOptions } from '@nestjs/throttler';

export const RATE_LIMIT_CONFIGS = {
  /** Default rate limit: 100 requests per minute */
  default: {
    ttl: 60000,
    limit: 100,
  },

  /** Auth endpoints: stricter limit to prevent brute force */
  auth: {
    ttl: 60000,
    limit: 10,
  },

  /** Login specifically: very strict */
  login: {
    ttl: 300000, // 5 minutes
    limit: 5,
  },

  /** Password reset: prevent email flooding */
  passwordReset: {
    ttl: 3600000, // 1 hour
    limit: 3,
  },

  /** Search endpoints: moderate limit */
  search: {
    ttl: 60000,
    limit: 30,
  },

  /** Music API proxy: limit due to Deezer rate limits */
  music: {
    ttl: 60000,
    limit: 50,
  },

  /** WebSocket events: higher limit for real-time */
  websocket: {
    ttl: 60000,
    limit: 200,
  },

  /** File uploads: strict limit */
  upload: {
    ttl: 60000,
    limit: 5,
  },

  /** Admin endpoints: moderate */
  admin: {
    ttl: 60000,
    limit: 60,
  },
} as const;

export function getThrottlerConfig(): ThrottlerModuleOptions {
  return [
    {
      name: 'short',
      ttl: 1000,
      limit: 3,
    },
    {
      name: 'medium',
      ttl: 10000,
      limit: 20,
    },
    {
      name: 'long',
      ttl: 60000,
      limit: 100,
    },
  ];
}

export type RateLimitCategory = keyof typeof RATE_LIMIT_CONFIGS;
