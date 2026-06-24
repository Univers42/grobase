import AsyncStorage from '@react-native-async-storage/async-storage';

const QUEUE_KEY = '@offline_queue';
const CACHE_PREFIX = '@cache_';

export interface OfflineAction {
  id: string;
  type: 'api_call';
  method: 'POST' | 'PATCH' | 'DELETE' | 'PUT';
  url: string;
  body?: any;
  timestamp: number;
  retryCount: number;
}

/**
 * OfflineQueue — persists failed API calls for retry when back online
 */
export class OfflineQueue {
  private static instance: OfflineQueue;

  static getInstance(): OfflineQueue {
    if (!OfflineQueue.instance) {
      OfflineQueue.instance = new OfflineQueue();
    }
    return OfflineQueue.instance;
  }

  /**
   * Add a failed API call to the offline queue
   */
  async enqueue(action: Omit<OfflineAction, 'id' | 'timestamp' | 'retryCount'>): Promise<void> {
    const queue = await this.getQueue();
    const entry: OfflineAction = {
      ...action,
      id: `${Date.now()}_${Math.random().toString(36).slice(2, 9)}`,
      timestamp: Date.now(),
      retryCount: 0,
    };
    queue.push(entry);
    await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(queue));
  }

  /**
   * Get all pending offline actions
   */
  async getQueue(): Promise<OfflineAction[]> {
    try {
      const raw = await AsyncStorage.getItem(QUEUE_KEY);
      return raw ? JSON.parse(raw) : [];
    } catch {
      return [];
    }
  }

  /**
   * Remove a specific action from the queue (after successful sync)
   */
  async dequeue(actionId: string): Promise<void> {
    const queue = await this.getQueue();
    const filtered = queue.filter((a) => a.id !== actionId);
    await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(filtered));
  }

  /**
   * Increment retry count for a failed action
   */
  async markRetry(actionId: string): Promise<void> {
    const queue = await this.getQueue();
    const idx = queue.findIndex((a) => a.id === actionId);
    if (idx !== -1) {
      queue[idx].retryCount += 1;
    }
    await AsyncStorage.setItem(QUEUE_KEY, JSON.stringify(queue));
  }

  /**
   * Clear all pending actions
   */
  async clear(): Promise<void> {
    await AsyncStorage.removeItem(QUEUE_KEY);
  }

  /**
   * Get queue size
   */
  async size(): Promise<number> {
    const queue = await this.getQueue();
    return queue.length;
  }
}

/**
 * CacheManager — simple key-value cache with TTL using AsyncStorage
 */
export class CacheManager {
  private static instance: CacheManager;

  static getInstance(): CacheManager {
    if (!CacheManager.instance) {
      CacheManager.instance = new CacheManager();
    }
    return CacheManager.instance;
  }

  /**
   * Cache a value with optional TTL (in milliseconds)
   */
  async set<T>(key: string, value: T, ttlMs?: number): Promise<void> {
    const entry = {
      data: value,
      cachedAt: Date.now(),
      expiresAt: ttlMs ? Date.now() + ttlMs : null,
    };
    await AsyncStorage.setItem(`${CACHE_PREFIX}${key}`, JSON.stringify(entry));
  }

  /**
   * Get a cached value (returns null if expired or not found)
   */
  async get<T>(key: string): Promise<T | null> {
    try {
      const raw = await AsyncStorage.getItem(`${CACHE_PREFIX}${key}`);
      if (!raw) return null;

      const entry = JSON.parse(raw);
      if (entry.expiresAt && Date.now() > entry.expiresAt) {
        await AsyncStorage.removeItem(`${CACHE_PREFIX}${key}`);
        return null;
      }
      return entry.data as T;
    } catch {
      return null;
    }
  }

  /**
   * Remove a cached value
   */
  async remove(key: string): Promise<void> {
    await AsyncStorage.removeItem(`${CACHE_PREFIX}${key}`);
  }

  /**
   * Clear all cached data
   */
  async clearAll(): Promise<void> {
    const keys = await AsyncStorage.getAllKeys();
    const cacheKeys = keys.filter((k) => k.startsWith(CACHE_PREFIX));
    await AsyncStorage.multiRemove(cacheKeys);
  }

  /**
   * Check if a cached value exists and is fresh
   */
  async has(key: string): Promise<boolean> {
    const value = await this.get(key);
    return value !== null;
  }
}
