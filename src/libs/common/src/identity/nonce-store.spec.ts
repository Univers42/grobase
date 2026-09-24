import { describe, expect, it } from '@jest/globals';
import { createNonceStore, MemoryNonceStore, NonceSetClient, RedisNonceStore } from './nonce-store';

// Replay-cache adapters behind the NonceStore port (H-14). The Redis client is a
// hand-rolled fake that records every SET so the exact command shape is pinned.

type SetCall = [string, string, 'PX', number, 'NX'];

function fakeRedis(): NonceSetClient & { calls: SetCall[] } {
  const keys = new Set<string>();
  const calls: SetCall[] = [];
  return {
    calls,
    set: async (key, value, px, ttlMs, nx) => {
      calls.push([key, value, px, ttlMs, nx]);
      if (keys.has(key)) return null;
      keys.add(key);
      return 'OK';
    },
  };
}

function failingRedis(): NonceSetClient & { attempts: number } {
  const client = {
    attempts: 0,
    set: async () => {
      client.attempts += 1;
      throw new Error('ECONNREFUSED redis:6379');
    },
  };
  return client;
}

describe('MemoryNonceStore', () => {
  it('accepts a fresh nonce and rejects the same kid:nonce again', () => {
    const store = new MemoryNonceStore();
    expect(store.remember('k1', 'n1', 60_000)).toBe(true);
    expect(store.remember('k1', 'n1', 60_000)).toBe(false);
  });

  it('scopes nonces per kid', () => {
    const store = new MemoryNonceStore();
    expect(store.remember('k1', 'n1', 60_000)).toBe(true);
    expect(store.remember('k2', 'n1', 60_000)).toBe(true);
  });

  it('forgets a nonce once it is older than the ttl (lazy prune)', () => {
    const store = new MemoryNonceStore();
    const realNow = Date.now;
    try {
      Date.now = () => 1_000;
      expect(store.remember('k1', 'n1', 500)).toBe(true);
      Date.now = () => 1_400;
      expect(store.remember('k1', 'n1', 500)).toBe(false);
      Date.now = () => 1_501;
      expect(store.remember('k1', 'n1', 500)).toBe(true);
    } finally {
      Date.now = realNow;
    }
  });
});

describe('RedisNonceStore', () => {
  it('first remember is true, the replay is false', async () => {
    const store = new RedisNonceStore(fakeRedis());
    await expect(store.remember('k1', 'n1', 60_000)).resolves.toBe(true);
    await expect(store.remember('k1', 'n1', 60_000)).resolves.toBe(false);
  });

  it('issues SET identity:nonce:<kid>:<nonce> 1 PX <ttl> NX', async () => {
    const client = fakeRedis();
    await new RedisNonceStore(client).remember('k1', 'n1', 60_000);
    expect(client.calls).toEqual([['identity:nonce:k1:n1', '1', 'PX', 60_000, 'NX']]);
  });

  it('fails CLOSED on a Redis error (treated as a replay)', async () => {
    const client = failingRedis();
    const store = new RedisNonceStore(client);
    await expect(store.remember('k1', 'n1', 60_000)).resolves.toBe(false);
    await expect(store.remember('k1', 'n2', 60_000)).resolves.toBe(false);
    expect(client.attempts).toBe(2);
  });
});

describe('createNonceStore (IDENTITY_NONCE_STORE selection)', () => {
  it('unset → MemoryNonceStore (OSS parity)', () => {
    expect(createNonceStore({})).toBeInstanceOf(MemoryNonceStore);
  });

  it.each(['memory', ' Memory ', ''])('%p → MemoryNonceStore', (value) => {
    expect(createNonceStore({ IDENTITY_NONCE_STORE: value })).toBeInstanceOf(MemoryNonceStore);
  });

  it.each(['REDIS', 'redis '])('%p → RedisNonceStore (case and spaces ignored)', (value) => {
    expect(
      createNonceStore({
        IDENTITY_NONCE_STORE: value,
        IDENTITY_NONCE_REDIS_URL: 'redis://127.0.0.1:1',
      }),
    ).toBeInstanceOf(RedisNonceStore);
  });

  it.each(['redsi', 'on', 'true'])('%p is refused, never a silent downgrade to memory', (value) => {
    expect(() => createNonceStore({ IDENTITY_NONCE_STORE: value })).toThrow(/IDENTITY_NONCE_STORE/);
  });

  it('redis → RedisNonceStore (lazyConnect: no socket opened here)', () => {
    const store = createNonceStore({
      IDENTITY_NONCE_STORE: 'redis',
      IDENTITY_NONCE_REDIS_URL: 'redis://127.0.0.1:1',
    });
    expect(store).toBeInstanceOf(RedisNonceStore);
  });
});
