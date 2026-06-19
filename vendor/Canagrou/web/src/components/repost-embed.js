// repost-embed.js — the inset card a repost shows: the ORIGINAL post fetched by
// id (its author header + content + image), bordered to read as quoted content.
// Self-loads asynchronously; shows a skeleton then the original, or a muted
// "original unavailable" note if the source post was removed.

import { baas } from '../lib/baas.js';
import { timeAgo } from '../../../services/index.js';
import { el, escapeHtml } from '../lib/dom.js';
import { resolvePostImage } from '../lib/images.js';
import { authorName, loadProfiles } from '../lib/profiles.js';
import { linkifyContent } from '../lib/hashtags.js';
import { avatar } from './icons.js';

/**
 * renderRepostEmbed returns a bordered container that asynchronously fills with
 * the original post (header + content + image). Returns immediately with a
 * skeleton so the card lays out without waiting on the fetch.
 * @param originalId the shared_post_id pointing at the source post
 */
export function renderRepostEmbed(originalId) {
  const box = el('div', { class: 'mx-4 mb-3 rounded-xl border border-ig-border overflow-hidden bg-ig-bg/40', dataset: { testid: 'repost-embed' } }, [loadingRow()]);
  fillEmbed(box, originalId);
  return box;
}

/** loadingRow shows a small placeholder while the original post loads. */
function loadingRow() {
  return el('div', { class: 'flex items-center gap-2.5 p-3' }, [
    el('div', { class: 'skeleton skeleton-avatar w-7 h-7' }),
    el('div', { class: 'skeleton skeleton-line w-24' }),
  ]);
}

/** fillEmbed fetches the original post + its author and renders, or notes loss. */
async function fillEmbed(box, originalId) {
  try {
    const [rows] = await Promise.all([
      baas.db.list('posts', { where: { id: originalId }, limit: 1 }),
      loadProfiles(),
    ]);
    box.replaceChildren(rows[0] ? originalCard(rows[0]) : unavailable());
  } catch (err) {
    box.replaceChildren(unavailable());
    console.warn('[repost] load failed', err && err.message);
  }
}

/** originalCard renders the quoted source post (header, content, image). */
function originalCard(post) {
  const name = authorName(post.user_id);
  const parts = [originalHeader(name, post)];
  if (post.content) parts.push(el('div', { class: 'px-3 pb-2 text-sm text-ig-text whitespace-pre-wrap break-words' }, linkifyContent(post.content)));
  if (post.image_key) parts.push(originalImage(post, name));
  return el('div', {}, parts);
}

/** originalHeader is the quoted post's author strip (also a profile link). */
function originalHeader(name, post) {
  return el('a', {
    href: `/profile/${encodeURIComponent(post.user_id || '')}`,
    'data-link': true,
    class: 'flex items-center gap-2.5 p-3',
    dataset: { testid: 'profile-link' },
  }, [
    avatar(name, 'w-7 h-7'),
    el('div', { class: 'min-w-0' }, [
      el('p', { class: 'text-xs font-semibold text-ig-text leading-tight truncate hover:underline' }, [name]),
      el('p', { class: 'text-[10px] text-ig-muted leading-tight' }, [timeAgo(post.created_at)]),
    ]),
  ]);
}

/** originalImage renders the quoted post's photo with a fade-in. */
function originalImage(post, name) {
  const img = el('img', { alt: `Photo by ${escapeHtml(name)}`, class: 'media-fade w-full max-h-80 object-cover', loading: 'lazy' });
  img.addEventListener('load', () => img.classList.add('loaded'));
  resolvePostImage(img, post.image_key);
  return el('div', { class: 'bg-ig-bg relative overflow-hidden' }, [img]);
}

/** unavailable renders the muted note shown when the original was removed. */
function unavailable() {
  return el('p', { class: 'text-ig-muted text-sm text-center py-4 px-3' }, ['Original post is no longer available.']);
}
