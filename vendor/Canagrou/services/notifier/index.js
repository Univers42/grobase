// notifier/index.js — best-effort "someone commented on your post" email hook.
// There is no edge function deployed on this stack, so this degrades to a no-op
// that console.logs and NEVER throws (a notification failure must not break
// commenting). It takes `baas` as a parameter rather than importing it, keeping
// the services/ layer free of a hard SDK dependency.

/**
 * commentNotify looks up the post's author profile, respects their
 * notify_comments preference, and would invoke a `comment-notify` edge function
 * if one existed. Any error is swallowed (logged) so the caller's comment insert
 * still succeeds.
 * @param baas    the configured Grobase client (auth/db/storage/realtime)
 * @param postId  the post that was commented on
 * @param content the comment text (passed to the notifier payload)
 * @returns Promise<boolean> true if a notification was (would be) dispatched
 */
export async function commentNotify({ baas, postId, content }) {
  try {
    const author = await resolveAuthor(baas, postId);
    if (!author) return false;
    if (!author.notify_comments) return false;
    return dispatchNotification({ baas, author, postId, content });
  } catch (err) {
    console.warn('[notifier] commentNotify skipped:', err && err.message ? err.message : err);
    return false;
  }
}

/** resolveAuthor finds the post then its author profile, or null if missing. */
async function resolveAuthor(baas, postId) {
  const posts = await baas.db.list('posts', { where: { id: postId }, limit: 1 });
  const post = posts[0];
  if (!post) return null;
  const profiles = await baas.db.list('profiles', { where: { id: post.user_id }, limit: 1 });
  return profiles[0] || null;
}

/**
 * dispatchNotification is the stub for the (not-yet-deployed) comment-notify
 * edge function. Until that function ships, it logs intent and returns false so
 * callers can tell nothing was actually sent.
 */
function dispatchNotification({ author, postId, content }) {
  // ponytail: no edge function deployed — log-only stub; wire baas function call here when `comment-notify` ships
  console.info(
    `[notifier] would email ${author.username || author.id} about a comment on post ${postId}:`,
    String(content).slice(0, 80),
  );
  return false;
}

export const notifier = { commentNotify };
