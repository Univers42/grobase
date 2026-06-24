// post-like.js — the like control for a post card: the heart button plus the
// optimistic toggle (instant fill + count, revert + toast on error) and the
// like-count label helpers. Split out of post-card.js to keep that file focused
// on layout. The viewer's liked state is loaded by the card's initState.

import { baas } from '../lib/baas.js';
import { el, toast } from '../lib/dom.js';
import { icon } from './icons.js';

/**
 * likeButton returns the heart toggle bound to the optimistic like flow for a
 * post, updating the supplied count label.
 * @param post      the post row
 * @param likeCount the count label element to keep in sync
 */
export function likeButton(post, likeCount) {
  const svg = icon('heart', 'w-7 h-7');
  const btn = el('button', { class: 'like-btn', title: 'Like', 'aria-label': 'Like', dataset: { liked: '0', testid: 'like-btn' } }, [svg]);
  btn.addEventListener('click', () => toggleLike(post, btn, svg, likeCount));
  return btn;
}

/** toggleLike optimistically flips the heart + count, reverting on error. */
async function toggleLike(post, btn, svg, likeCount) {
  const user = baas.auth.currentUser();
  if (!user) {
    toast('Log in to like posts', 'info');
    window.canagrouNavigate('/login');
    return;
  }
  const liked = btn.dataset.liked === '1';
  applyOptimistic(btn, svg, likeCount, !liked);
  try {
    if (liked) await baas.db.remove('likes', { user_id: user.id, post_id: post.id });
    else await baas.db.insert('likes', { user_id: user.id, post_id: post.id });
    const likes = await baas.db.list('likes', { where: { post_id: post.id }, limit: 500 });
    setLikeCount(likeCount, likes.length);
  } catch (err) {
    applyOptimistic(btn, svg, likeCount, liked, true);
    toast(err && err.message ? err.message : 'Could not update your like', 'error');
  }
}

/** applyOptimistic flips the heart fill + count instantly (delta ±1). */
function applyOptimistic(btn, svg, likeCount, liked, revert = false) {
  markLiked(btn, svg, liked);
  if (!revert) btn.classList.add('pop');
  setTimeout(() => btn.classList.remove('pop'), 420);
  const current = parseInt(likeCount.textContent, 10) || 0;
  const next = Math.max(0, liked ? current + (revert ? 0 : 1) : current - (revert ? 0 : 1));
  setLikeCount(likeCount, next);
}

/** markLiked toggles the filled-heart styling and the liked data flag. */
export function markLiked(btn, svg, liked) {
  btn.dataset.liked = liked ? '1' : '0';
  svg.setAttribute('fill', liked ? 'currentColor' : 'none');
}

/** setLikeCount writes the "N like(s)" label from a count. */
export function setLikeCount(node, count) {
  node.textContent = `${count} like${count === 1 ? '' : 's'}`;
}
