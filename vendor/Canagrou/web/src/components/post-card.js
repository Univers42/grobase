// post-card.js — one gallery post: the stored image, author + relative time, a
// like button with live count (toggles the likes table), and a comment toggle
// that lazily mounts the comment-list. Mirrors the feed.php card markup.

import { baas } from '../lib/baas.js';
import { timeAgo } from '../../../services/index.js';
import { el, escapeHtml, toast } from '../lib/dom.js';
import { resolvePostImage } from '../lib/images.js';
import { authorName } from '../lib/profiles.js';
import { createCommentList } from './comment-list.js';

const HEART =
  '<path stroke-linecap="round" stroke-linejoin="round" ' +
  'd="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/>';

/**
 * createPostCard builds a full post card element. It self-loads its image, like
 * state, and comment count, and wires the like + comment-toggle interactions.
 * @param post the post row {id,user_id,image_key,created_at}
 */
export function createPostCard(post) {
  const name = authorName(post.user_id);
  const card = el('article', {
    class: 'bg-white border border-ig-border rounded-lg overflow-hidden fade-in-up',
    dataset: { postId: String(post.id) },
  });
  card.append(authorBar(name), imageBlock(post, name), actions(post, name));
  return card;
}

/** authorBar renders the avatar + username header strip. */
function authorBar(name) {
  const avatar = el(
    'div',
    { class: 'w-8 h-8 rounded-full bg-gradient-to-br from-yellow-400 via-pink-500 to-purple-600 p-[2px] flex-shrink-0' },
    [
      el('div', { class: 'w-full h-full rounded-full bg-white flex items-center justify-center' }, [
        el('span', { class: 'text-xs font-semibold text-ig-text' }, [name.charAt(0).toUpperCase()]),
      ]),
    ],
  );
  return el('div', { class: 'flex items-center gap-3 px-4 py-3' }, [
    avatar,
    el('span', { class: 'text-sm font-semibold text-ig-text' }, [name]),
  ]);
}

/** imageBlock builds the square image container and resolves its storage key. */
function imageBlock(post, name) {
  const img = el('img', {
    alt: `Creation by ${escapeHtml(name)}`,
    class: 'w-full h-full object-cover',
    loading: 'lazy',
  });
  resolvePostImage(img, post.image_key);
  return el('div', { class: 'bg-gray-50 aspect-square relative overflow-hidden' }, [img]);
}

/** actions builds the like/comment bar, counts, time, and comment panel host. */
function actions(post, name) {
  const likeCount = el('span', { class: 'text-sm font-semibold text-ig-text' }, ['0 likes']);
  const likeBtn = likeButton(post, likeCount);
  const commentsHost = el('div', { class: 'hidden' });
  const commentBtn = commentButton(post, commentsHost);
  const wrap = el('div', { class: 'px-4 pt-3 pb-1' }, [
    el('div', { class: 'flex items-center gap-4 mb-2' }, [likeBtn, commentBtn]),
    el('div', { class: 'mb-1' }, [likeCount]),
    el('div', { class: 'mb-1' }, [
      el('span', { class: 'text-sm font-semibold text-ig-text' }, [name]),
      el('span', { class: 'text-sm text-ig-text ml-1' }, ['shared a creation']),
    ]),
    el('p', { class: 'text-[10px] text-ig-muted uppercase tracking-wide mt-1 mb-2' }, [timeAgo(post.created_at)]),
  ]);
  const container = el('div', {}, [wrap, commentsHost]);
  initLikeState(post, likeBtn, likeCount);
  return container;
}

/** likeButton returns the heart toggle button bound to like/unlike. */
function likeButton(post, likeCount) {
  const svg = svgIcon(HEART, 'none');
  const btn = el('button', { class: 'like-btn group', title: 'Like' }, [svg]);
  btn.dataset.liked = '0';
  btn.addEventListener('click', () => toggleLike(post, btn, svg, likeCount));
  return btn;
}

/** commentButton returns the speech-bubble toggle that mounts comments lazily. */
function commentButton(post, host) {
  const svg = svgIcon(
    '<path stroke-linecap="round" stroke-linejoin="round" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"/>',
    'none',
  );
  const btn = el('button', { class: 'text-ig-text hover:text-gray-500 transition-colors', title: 'Comments' }, [svg]);
  btn.addEventListener('click', () => toggleComments(post, host));
  return btn;
}

/** svgIcon builds a 24px stroked SVG with the given inner path and fill. */
function svgIcon(inner, fill) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', 'w-6 h-6 transition-colors');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.setAttribute('fill', fill);
  svg.innerHTML = inner;
  return svg;
}

/** initLikeState loads the current like count and whether the user liked it. */
async function initLikeState(post, btn, likeCount) {
  try {
    const likes = await baas.db.list('likes', { where: { post_id: post.id }, limit: 500 });
    setLikeCount(likeCount, likes.length);
    const user = baas.auth.currentUser();
    if (user && likes.some((l) => l.user_id === user.id)) markLiked(btn, btn.firstChild, true);
  } catch (err) {
    console.warn('[post-card] like state failed', err && err.message);
  }
}

/** toggleLike inserts or removes the current user's like and updates the count. */
async function toggleLike(post, btn, svg, likeCount) {
  const user = baas.auth.currentUser();
  if (!user) {
    window.canagrouNavigate('/login');
    return;
  }
  const liked = btn.dataset.liked === '1';
  try {
    if (liked) await baas.db.remove('likes', { user_id: user.id, post_id: post.id });
    else await baas.db.insert('likes', { user_id: user.id, post_id: post.id });
    markLiked(btn, svg, !liked);
    const likes = await baas.db.list('likes', { where: { post_id: post.id }, limit: 500 });
    setLikeCount(likeCount, likes.length);
  } catch (err) {
    toast(err && err.message ? err.message : 'Like failed', 'error');
  }
}

/** markLiked toggles the filled-heart styling and the liked data flag. */
function markLiked(btn, svg, liked) {
  btn.dataset.liked = liked ? '1' : '0';
  svg.setAttribute('fill', liked ? 'currentColor' : 'none');
  svg.classList.toggle('text-ig-red', liked);
}

/** setLikeCount writes the "N like(s)" label from a count. */
function setLikeCount(node, count) {
  node.textContent = `${count} like${count === 1 ? '' : 's'}`;
}

/** toggleComments lazily mounts the comment-list then shows/hides the host. */
function toggleComments(post, host) {
  if (!host.dataset.mounted) {
    const { element } = createCommentList(post.id);
    host.append(element);
    host.dataset.mounted = '1';
  }
  host.classList.toggle('hidden');
}
