import type { BaasConfig } from './config.ts';
import { listRows, runQuery } from './query.ts';
import type { WatchState } from './types.ts';

/** watchedSet reads the caller's OWN watch_state rows (Bearer-scoped, per user)
 *  and returns the set of watched movie ids. Empty set on any error so a missing
 *  DynamoDB mount or an empty partition never breaks the library render. */
export async function watchedSet(cfg: BaasConfig): Promise<Set<string>> {
  if (!cfg.dynamoDbId) return new Set();
  try {
    const rows = await listRows<WatchState>(cfg, cfg.dynamoDbId, 'watch_state', {});
    return new Set(rows.filter((r) => r.watched).map((r) => r.id));
  } catch {
    return new Set();
  }
}

/** markWatched upserts a watched flag + progress for a movie's watch_state row. */
export async function markWatched(cfg: BaasConfig, movieId: string, progressSec: number): Promise<void> {
  if (!cfg.dynamoDbId) return;
  await runQuery(cfg, cfg.dynamoDbId, 'watch_state', {
    op: 'upsert',
    data: { id: movieId, watched: true, progress_sec: Math.floor(progressSec), updated_at: new Date().toISOString() },
  });
}
