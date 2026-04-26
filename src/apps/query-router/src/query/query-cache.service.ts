import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

interface CacheEntry<T> {
  expiresAt: number;
  value: T;
}

@Injectable()
export class QueryCacheService {
  private readonly entries = new Map<string, CacheEntry<unknown>>();
  private readonly inFlight = new Map<string, Promise<unknown>>();
  readonly adapterTtlMs: number;
  readonly permissionTtlMs: number;
  readonly readTtlMs: number;
  readonly maxEntries: number;

  constructor(config: ConfigService) {
    this.adapterTtlMs = config.get<number>('QUERY_ROUTER_ADAPTER_CACHE_TTL_MS', 30_000);
    this.permissionTtlMs = config.get<number>('QUERY_ROUTER_PERMISSION_CACHE_TTL_MS', 5_000);
    this.readTtlMs = config.get<number>('QUERY_ROUTER_READ_CACHE_TTL_MS', 3_000);
    this.maxEntries = config.get<number>('QUERY_ROUTER_CACHE_MAX_ENTRIES', 2_000);
  }

  key(...parts: Array<string | number | boolean | undefined | null>): string {
    return parts.map((part) => encodeURIComponent(String(part ?? ''))).join(':');
  }

  get<T>(key: string): T | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;

    if (Date.now() > entry.expiresAt) {
      this.entries.delete(key);
      return undefined;
    }

    return entry.value as T;
  }

  set<T>(key: string, value: T, ttlMs: number): void {
    if (ttlMs <= 0) return;

    if (this.entries.size >= this.maxEntries) {
      const oldestKey = this.entries.keys().next().value as string | undefined;
      if (oldestKey) this.entries.delete(oldestKey);
    }

    this.entries.set(key, {
      expiresAt: Date.now() + ttlMs,
      value,
    });
  }

  deletePrefix(prefix: string): void {
    for (const key of this.entries.keys()) {
      if (key.startsWith(prefix)) this.entries.delete(key);
    }
  }

  getInFlight<T>(key: string): Promise<T> | undefined {
    return this.inFlight.get(key) as Promise<T> | undefined;
  }

  coalesce<T>(key: string, operation: () => Promise<T>): Promise<T> {
    const existing = this.getInFlight<T>(key);
    if (existing) return existing;

    const promise = operation().finally(() => {
      this.inFlight.delete(key);
    });
    this.inFlight.set(key, promise as Promise<unknown>);
    return promise;
  }
}
