// post-card.js — one feed post: author header (avatar + username both link to
// the author's profile, relative time), optional text content with clickable
// #hashtags, an optional image, an optional embedded repost of an original post,
// and an actions bar (like · comment · share). Self-loads its image, like state,
// comment count, and share count. Like/comment/share interactions live here and
// in repost-embed.js / share-composer.js.

import { baas } from '../lib/baas.js';
import { timeAgo } from '../../../services/index.js';
import { el, escapeHtml } from '../lib/dom.js';
import { resolvePostImage, isVideoKey } from '../lib/images.js';
import { authorName } from '../lib/profiles.js';
import { linkifyContent } from '../lib/hashtags.js';
import { icon, avatar } from './icons.js';
import { createCommentList } from './comment-list.js';
import { renderRepostEmbed } from './repost-embed.js';
import { openShareComposer } from './share-composer.js';
import { likeButton, markLiked, setLikeCount } from './post-like.js';

/**
 * createPostCard builds a full post card element. It self-loads its image, like
 * state, comment count, share count, and (for reposts) the embedded original.
 * @param post     the post row {id,user_id,content,image_key,shared_post_id,created_at}
 * @param onChange optional callback the share flow calls to refresh the feed
 */
export function createPostCard(post, onChange) {
  const name = authorName(post.user_id);
  const card = el('article', {
    class: 'card card-hover overflow-hidden fade-in-up',
    dataset: { postId: String(post.id), testid: 'post-card' },
  });
  card.append(authorBar(name, post), bodyBlock(post, name), actions(post, name, onChange));
  return card;
}

/** authorBar renders the avatar + username (both profile links) + relative time. */
function authorBar(name, post) {
  const link = profileLink(post.user_id);
  link.append(
    avatar(name, 'w-9 h-9'),
    el('div', { class: 'min-w-0' }, [
      el('p', { class: 'text-sm font-semibold text-ig-text leading-tight truncate hover:underline' }, [name]),
      el('p', { class: 'text-[11px] text-ig-muted leading-tight' }, [post.shared_post_id ? `🔁 ${name} reposted · ${timeAgo(post.created_at)}` : timeAgo(post.created_at)]),
    ]),
  );
  return el('div', { class: 'flex items-center gap-3 px-4 py-3' }, [link]);
}

/** profileLink returns the [data-link] anchor wrapping the author identity. */
function profileLink(userId) {
  return el('a', {
    href: `/profile/${encodeURIComponent(userId || '')}`,
    'data-link': true,
    class: 'flex items-center gap-3 min-w-0 group',
    dataset: { testid: 'profile-link' },
  });
}

/** bodyBlock assembles content text, the repost embed, and the image. */
function bodyBlock(post, name) {
  const block = el('div', {});
  if (post.content) block.append(contentText(post.content));
  if (post.shared_post_id) block.append(renderRepostEmbed(post.shared_post_id));
  else if (post.image_key) block.append(imageBlock(post, name));
  return block;
}

/** contentText renders the escaped, hashtag-linkified post body. */
function contentText(content) {
  return el('div', {
    class: 'px-4 pb-3 text-sm text-ig-text whitespace-pre-wrap break-words leading-relaxed',
    dataset: { testid: 'post-content' },
  }, linkifyContent(content));
}

/** imageBlock builds the aspect-reserved media container (img or video) with a
 * fade-in. Videos (mp4/webm/…) render as a controllable <video>; everything else
 * (png/jpg/webp/gif) as an <img>. The blob is fetched LAZILY when the media
 * scrolls near the viewport — fetching every feed image at once overwhelms the
 * gateway (stragglers/429); one-at-a-time-on-scroll loads reliably. */
function imageBlock(post, name) {
  const video = isVideoKey(post.image_key);
  const media = video
    ? el('video', { class: 'media-fade w-full h-full object-cover', controls: true, playsinline: true, preload: 'metadata', 'aria-label': `Video by ${escapeHtml(name)}` })
    : el('img', { class: 'media-fade w-full h-full object-cover', loading: 'lazy', alt: `Photo by ${escapeHtml(name)}` });
  media.dataset.mediaKey = post.image_key || '';
  lazyLoadMedia(media);
  return el('div', { class: 'bg-ig-bg aspect-square relative overflow-hidden' }, [media]);
}

/** lazyLoadMedia resolves a media element's blob when it nears the viewport,
 * via a shared IntersectionObserver (falls back to eager load when unsupported);
 * already-visible cards load immediately. */
function lazyLoadMedia(media) {
  if (typeof IntersectionObserver === 'undefined') {
    resolvePostImage(media, media.dataset.mediaKey);
    return;
  }
  mediaObserver().observe(media);
}

/** mediaObserver returns the singleton observer that loads media on intersect. */
function mediaObserver() {
  if (!createPostCard._io) {
    createPostCard._io = new IntersectionObserver(
      (entries, obs) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          obs.unobserve(e.target);
          resolvePostImage(e.target, e.target.dataset.mediaKey);
        }
      },
      { rootMargin: '300px' },
    );
  }
  return createPostCard._io;
}

/** actions builds the like/comment/share bar, counts, and comment host. */
function actions(post, name, onChange) {
  const likeCount = el('span', { class: 'text-sm font-semibold text-ig-text', dataset: { testid: 'like-count' } }, ['0 likes']);
  const shareCount = el('span', { class: 'text-xs text-ig-muted', dataset: { testid: 'share-count' } }, ['']);
  const likeBtn = likeButton(post, likeCount);
  const commentsHost = el('div', { class: 'hidden' });
  const preview = el('button', {
    class: 'block w-full text-left text-sm text-ig-muted hover:text-ig-text transition-colors',
    dataset: { testid: 'comment-toggle' },
  }, ['View comments']);
  preview.addEventListener('click', () => toggleComments(post, commentsHost, preview));
  const bar = el('div', { class: 'flex items-center gap-4 mb-2' }, [
    likeBtn, commentButton(post, commentsHost, preview), shareButton(post, onChange),
  ]);
  const wrap = el('div', { class: 'px-4 pt-3 pb-3' }, [
    bar,
    el('div', { class: 'flex items-center gap-3 mb-1' }, [likeCount, shareCount]),
    el('div', { class: 'mt-1.5' }, [preview]),
  ]);
  initState(post, likeBtn, likeCount, preview, shareCount);
  return el('div', {}, [wrap, commentsHost]);
}

/** commentButton returns the speech-bubble toggle that opens the comments. */
function commentButton(post, host, preview) {
  const btn = el('button', { class: 'action-btn', title: 'Comments', 'aria-label': 'Comments' }, [icon('comment', 'w-7 h-7')]);
  btn.addEventListener('click', () => toggleComments(post, host, preview));
  return btn;
}

/** shareButton returns the repost toggle opening the inline share composer. */
function shareButton(post, onChange) {
  const btn = el('button', { class: 'action-btn', title: 'Share', 'aria-label': 'Share', dataset: { testid: 'share-btn' } }, [icon('retry', 'w-7 h-7')]);
  btn.addEventListener('click', () => openShareComposer(post, btn, onChange));
  return btn;
}

/** initState loads the like/comment/share counts and the viewer's liked flag. */
async function initState(post, btn, likeCount, preview, shareCount) {
  try {
    const [likes, comments, shares] = await Promise.all([
      baas.db.list('likes', { where: { post_id: post.id }, limit: 500 }),
      baas.db.list('comments', { where: { post_id: post.id }, limit: 200 }),
      baas.db.list('posts', { where: { shared_post_id: post.id }, limit: 500 }),
    ]);
    setLikeCount(likeCount, likes.length);
    setPreview(preview, comments.length);
    setShareCount(shareCount, shares.length);
    const user = baas.auth.currentUser();
    if (user && likes.some((l) => l.user_id === user.id)) markLiked(btn, btn.firstChild, true);
  } catch (err) {
    console.warn('[post-card] state failed', err && err.message);
  }
}

/** setShareCount writes the "N share(s)" label, hiding it at zero. */
function setShareCount(node, count) {
  node.textContent = count ? `${count} repost${count === 1 ? '' : 's'}` : '';
}

/** setPreview updates the "view all N comments" label from a count. */
function setPreview(preview, count) {
  if (!count) {
    preview.textContent = preview.dataset.open === '1' ? 'Hide comments' : 'Add a comment…';
    return;
  }
  preview.textContent = preview.dataset.open === '1' ? 'Hide comments' : `View all ${count} comment${count === 1 ? '' : 's'}`;
}

/** toggleComments lazily mounts the comment-list then shows/hides the host. */
function toggleComments(post, host, preview) {
  if (!host.dataset.mounted) {
    const { element } = createCommentList(post.id, (n) => setPreview(preview, n));
    host.append(element);
    host.dataset.mounted = '1';
  }
  const willOpen = host.classList.contains('hidden');
  host.classList.toggle('hidden', !willOpen);
  preview.dataset.open = willOpen ? '1' : '0';
  preview.textContent = willOpen ? 'Hide comments' : preview.textContent.replace('Hide comments', 'View comments');
}
