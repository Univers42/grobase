// profile-data.js — the data queries behind the profile page: a user's authored
// posts, the posts they liked (resolved via the likes table → $in), and the
// aggregate stats (post count + total likes received across their posts). Pure
// data access over baas.db; no DOM. Kept separate so profile.js stays UI-only.

import { baas } from '../lib/baas.js';

const POST_LIMIT = 100;

/** listUserPosts returns a user's authored posts, newest first. */
export function listUserPosts(userId) {
  return baas.db.list('posts', { where: { user_id: userId }, sort: { created_at: 'desc' }, limit: POST_LIMIT });
}

/**
 * listLikedPosts resolves the posts a user liked: list their likes, collect the
 * post ids, then fetch those posts ($in). Returns [] when they've liked nothing.
 * Ordering follows the posts query; missing originals are simply absent.
 * @param userId the profile owner's id
 */
export async function listLikedPosts(userId) {
  const likes = await baas.db.list('likes', { where: { user_id: userId }, limit: 500 });
  const ids = [...new Set(likes.map((l) => l.post_id))];
  if (!ids.length) return [];
  const posts = await baas.db.list('posts', { filter: { id: { $in: ids } }, limit: POST_LIMIT });
  return sortByLikeRecency(posts, likes);
}

/** sortByLikeRecency orders fetched posts by the order they appear in likes
 * (most-recently-liked first), so the Likes tab reads like an activity list. */
function sortByLikeRecency(posts, likes) {
  const rank = new Map();
  likes.forEach((l, i) => { if (!rank.has(l.post_id)) rank.set(l.post_id, i); });
  return posts.slice().sort((a, b) => (rank.get(a.id) ?? 1e9) - (rank.get(b.id) ?? 1e9));
}

/**
 * loadUserStats returns { posts, likesReceived } for a profile: the count of the
 * user's posts and the total likes across them (chunked $in to stay bounded).
 * @param userId the profile owner's id
 */
export async function loadUserStats(userId) {
  const posts = await baas.db.list('posts', { where: { user_id: userId }, limit: 500 });
  const ids = posts.map((p) => p.id);
  return { posts: posts.length, likesReceived: await countLikes(ids) };
}

/** countLikes sums likes over post ids in chunks (avoids an oversized $in). */
async function countLikes(ids) {
  let total = 0;
  for (let i = 0; i < ids.length; i += 50) {
    const chunk = ids.slice(i, i + 50);
    const likes = await baas.db.list('likes', { filter: { post_id: { $in: chunk } }, limit: 1000 });
    total += likes.length;
  }
  return total;
}
