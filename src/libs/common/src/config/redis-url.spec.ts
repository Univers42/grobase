import { describe, expect, it } from '@jest/globals';
import { DEFAULT_REDIS_URL, redisUrlFrom } from './redis-url';

const reader =
  (env: Record<string, string | undefined>) =>
  (name: string): string | undefined =>
    env[name];

describe('redisUrlFrom', () => {
  it('returns the first configured name, trimmed', () => {
    const read = reader({
      OUTBOX_REDIS_URL: ' redis://app:pw@redis:6379 ',
      REDIS_URL: 'redis://other:6379',
    });
    expect(redisUrlFrom(read, 'OUTBOX_REDIS_URL', 'REDIS_URL')).toBe('redis://app:pw@redis:6379');
  });

  it('falls through unset and blank names to the next one', () => {
    const read = reader({ OUTBOX_REDIS_URL: '   ', REDIS_URL: 'redis://app:pw@redis:6379' });
    expect(redisUrlFrom(read, 'MISSING', 'OUTBOX_REDIS_URL', 'REDIS_URL')).toBe(
      'redis://app:pw@redis:6379',
    );
  });

  // ioredis reads new Redis('') as localhost:6379, so a blank value must never be returned.
  it('returns the credential-free in-cluster default when every name is blank', () => {
    expect(redisUrlFrom(reader({ REDIS_URL: '' }), 'REDIS_URL')).toBe(DEFAULT_REDIS_URL);
    expect(DEFAULT_REDIS_URL).toBe('redis://redis:6379');
  });

  it('reads the names in the order given', () => {
    const read = reader({ A: 'redis://a:6379', B: 'redis://b:6379' });
    expect(redisUrlFrom(read, 'B', 'A')).toBe('redis://b:6379');
  });
});
