// post-feed.js — a reusable post list used by the tag and profile pages. Given a
// container and an async loader returning post rows, it paints skeletons, then
// renders a staggered post-card per row, or an empty/error state. Keeps the tag
// and profile feeds visually identical to the home feed without duplicating the
// skeleton/empty/error scaffolding.

import { el, clear, skeletonCard } from '../lib/dom.js';
import { loadProfiles } from '../lib/profiles.js';
import { createPostCard } from './post-card.js';
import { icon } from './icons.js';

const SKELETON_COUNT = 3;

/**
 * fillPostFeed loads posts via loadFn and renders cards into container, handling
 * skeleton, empty, and error states. onChange (optional) is forwarded to each
 * card so the share flow can refresh the list.
 * @param container the feed element to fill
 * @param loadFn    async () => post rows
 * @param emptyMsg  the message shown when there are no posts
 * @param onChange  optional callback re-running the feed (passed to cards)
 */
export async function fillPostFeed(container, loadFn, emptyMsg, onChange) {
  showSkeletons(container);
  try {
    const [posts] = await Promise.all([loadFn(), loadProfiles()]);
    clear(container);
    if (!posts.length) {
      container.append(emptyState(emptyMsg));
      return;
    }
    posts.forEach((post, i) => container.append(staggered(createPostCard(post, onChange), i)));
  } catch (err) {
    clear(container);
    container.append(errorState(() => fillPostFeed(container, loadFn, emptyMsg, onChange)));
    console.warn('[post-feed] load failed', err && err.message);
  }
}

/** showSkeletons paints placeholder cards while the load is in flight. */
function showSkeletons(container) {
  clear(container);
  for (let i = 0; i < SKELETON_COUNT; i++) container.append(skeletonCard());
}

/** staggered applies a small entrance delay so cards cascade in. */
function staggered(card, index) {
  card.style.animationDelay = `${Math.min(index, 6) * 60}ms`;
  return card;
}

/** emptyState renders a friendly "nothing here" card. */
function emptyState(message) {
  return el('div', { class: 'card text-center py-14 px-8 fade-in-up' }, [
    el('div', { class: 'inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-purple-50 text-purple-500 mb-4' }, [icon('image', 'w-7 h-7')]),
    el('p', { class: 'text-ig-muted text-sm' }, [message || 'No posts to show yet.']),
  ]);
}

/** errorState renders a failure card with a Retry button calling retryFn. */
function errorState(retryFn) {
  const retry = el('button', { class: 'btn btn-secondary px-5 py-2 text-sm' }, [icon('retry', 'w-4 h-4'), 'Retry']);
  retry.addEventListener('click', retryFn);
  return el('div', { class: 'card text-center py-14 px-8 fade-in-up' }, [
    el('div', { class: 'inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-red-50 text-ig-red mb-4' }, [icon('comment', 'w-7 h-7')]),
    el('h2', { class: 'text-lg font-bold text-ig-text mb-1.5' }, ["Couldn't load posts"]),
    el('p', { class: 'text-ig-muted text-sm mb-6' }, ['Check your connection and try again.']),
    retry,
  ]);
}
