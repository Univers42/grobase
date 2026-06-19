import type { BaasConfig } from './config.ts';
import { listRows, runQuery } from './query.ts';
import type { Comment, Profile } from './types.ts';

/** listComments reads a movie's comments (newest first) via the shared public
 *  path — the comments collection is owner-scoped on write, world-readable. */
export function listComments(cfg: BaasConfig, movieId: string): Promise<Comment[]> {
  return listRows<Comment>(
    cfg,
    cfg.mongoDbId,
    'comments',
    { filter: { movie_id: { $eq: movieId } }, sort: { created_at: 'desc' }, limit: 200 },
    { shared: true },
  );
}

/** postComment inserts a comment under the caller's identity (Bearer-scoped);
 *  the data plane stamps owner_id, the server fields fill author/date here. */
export async function postComment(cfg: BaasConfig, movieId: string, authorId: string, authorUsername: string, content: string): Promise<void> {
  await runQuery(cfg, cfg.mongoDbId, 'comments', {
    op: 'insert',
    data: {
      movie_id: movieId,
      author_id: authorId,
      author_username: authorUsername,
      content,
      created_at: new Date().toISOString(),
    },
  });
}

/** getProfile reads a single user's PUBLIC profile (never their email). */
export async function getProfile(cfg: BaasConfig, userId: string): Promise<Profile | null> {
  const rows = await listRows<Profile>(cfg, cfg.mongoDbId, 'profiles', { filter: { user_id: { $eq: userId } }, limit: 1 }, { shared: true });
  return rows[0] ?? null;
}

/** saveProfile upserts the caller's own profile fields (Bearer-scoped write). */
export async function saveProfile(cfg: BaasConfig, profile: Partial<Profile>): Promise<void> {
  await runQuery(cfg, cfg.mongoDbId, 'profiles', { op: 'upsert', data: { ...profile } });
}
