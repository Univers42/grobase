/** The in-cluster redis a consumer dials when no URL is configured. It carries no credential. */
export const DEFAULT_REDIS_URL = 'redis://redis:6379';

/**
 * The first non-blank value among `names`, read in order, else DEFAULT_REDIS_URL.
 * Credentials only ever come from the env: the REDIS_ACL overlay sets every name a
 * service declares (docs/adr/0028-g5-redis-acl-stage1.md). A blank value is skipped
 * because ioredis reads `new Redis('')` as localhost:6379.
 */
export function redisUrlFrom(
  read: (name: string) => string | undefined,
  ...names: string[]
): string {
  for (const name of names) {
    const url = read(name)?.trim();
    if (url) return url;
  }
  return DEFAULT_REDIS_URL;
}
