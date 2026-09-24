import { Logger } from '@nestjs/common';
import Redis from 'ioredis';

/**
 * Replay cache for signed identity envelopes. `remember` records `kid:nonce` and
 * returns false when that nonce was already seen within `ttlMs` (a replay).
 */
export interface NonceStore {
  remember(kid: string, nonce: string, ttlMs: number): Promise<boolean> | boolean;
}

/** The single ioredis command RedisNonceStore issues — a fake satisfies it in tests. */
export interface NonceSetClient {
  set(key: string, value: string, px: 'PX', ttlMs: number, nx: 'NX'): Promise<'OK' | null>;
}

/**
 * Per-process replay cache (the default, OSS parity). Entries are pruned lazily
 * on each call once older than `ttlMs`.
 */
export class MemoryNonceStore implements NonceStore {
  private readonly seen = new Map<string, number>();

  /** Records `kid:nonce`; false when it is still inside the ttl window. */
  remember(kid: string, nonce: string, ttlMs: number): boolean {
    const now = Date.now();
    this.prune(now, ttlMs);
    const key = `${kid}:${nonce}`;
    if (this.seen.has(key)) return false;
    this.seen.set(key, now);
    return true;
  }

  /**
   * Drops expired entries. The Map iterates in insertion order, which is
   * seen-at order, so the scan stops at the first entry still inside the window.
   */
  private prune(now: number, ttlMs: number): void {
    // perf: O(expired) early-exit over the insertion-ordered Map instead of a full O(n) scan per request
    for (const [key, seenAt] of this.seen) {
      if (now - seenAt <= ttlMs) return;
      this.seen.delete(key);
    }
  }
}

/**
 * Cross-replica replay cache: `SET identity:nonce:<kid>:<nonce> 1 PX ttl NX`.
 * Fails CLOSED — a Redis error is reported as a replay, logged once per outage.
 */
export class RedisNonceStore implements NonceStore {
  private readonly logger = new Logger(RedisNonceStore.name);
  private outageLogged = false;

  constructor(private readonly client: NonceSetClient) {}

  /** Resolves true only when Redis confirms the nonce was not already set. */
  async remember(kid: string, nonce: string, ttlMs: number): Promise<boolean> {
    try {
      const reply = await this.client.set(`identity:nonce:${kid}:${nonce}`, '1', 'PX', ttlMs, 'NX');
      this.outageLogged = false;
      return reply === 'OK';
    } catch (err) {
      this.logOutage(err);
      return false;
    }
  }

  /** Logs the first error of an outage; later errors stay quiet until a success. */
  private logOutage(err: unknown): void {
    if (this.outageLogged) return;
    this.outageLogged = true;
    const reason = err instanceof Error ? err.message : String(err);
    this.logger.error(`identity nonce store unavailable, rejecting envelopes: ${reason}`);
  }
}

/**
 * Builds the store named by IDENTITY_NONCE_STORE: exactly 'redis' selects Redis
 * (IDENTITY_NONCE_REDIS_URL || REDIS_URL || redis://redis:6379); anything else,
 * including unset, selects the in-memory store.
 */
export function createNonceStore(env: NodeJS.ProcessEnv): NonceStore {
  if (env['IDENTITY_NONCE_STORE'] !== 'redis') return new MemoryNonceStore();
  const url = (env['IDENTITY_NONCE_REDIS_URL'] || env['REDIS_URL'] || 'redis://redis:6379').trim();
  return new RedisNonceStore(new Redis(url, { lazyConnect: true, maxRetriesPerRequest: 2 }));
}

// ponytail: process-wide store built lazily on first use; env is read once, so changing IDENTITY_NONCE_STORE needs a restart — inject a NonceStore via Nest DI if per-module stores are ever needed
let processNonceStore: NonceStore | undefined;

/** Returns the process-wide store, creating it from process.env on first call. */
export function defaultNonceStore(): NonceStore {
  processNonceStore ??= createNonceStore(process.env);
  return processNonceStore;
}
