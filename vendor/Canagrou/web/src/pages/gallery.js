// gallery.js — the home feed. Shows the composer (authed) above shimmer
// skeletons while loading, a polished empty state, or an error state with Retry.
// Lists the latest posts (newest first), fills the id→username profile cache,
// renders a post-card per post, and live-refreshes on realtime changes to posts
// (new posts and reposts prepend); likes/comments update in-card.

import { baas } from '../lib/baas.js';
import { el, clear, skeletonCard } from '../lib/dom.js';
import { loadProfiles } from '../lib/profiles.js';
import { createPostCard } from '../components/post-card.js';
import { createComposer } from '../components/composer.js';
import { icon } from '../components/icons.js';

const POST_LIMIT = 30;
const SKELETON_COUNT = 3;

/**
 * render mounts the gallery into the slot: a header, the composer (authed), and a
 * centered feed column that lists posts and live-refreshes on realtime events.
 * Returns a cleanup function the router calls to close the realtime subscription.
 * @param slot the content container provided by the router
 * @returns cleanup function closing realtime subscriptions
 */
export default async function render(slot) {
  const feed = el('div', { id: 'gallery-feed', class: 'space-y-6', dataset: { testid: 'gallery-feed' } });
  const children = [header()];
  if (baas.auth.isAuthed()) children.push(createComposer(() => refresh(feed)));
  children.push(feed);
  const wrap = el('div', { class: 'max-w-[500px] mx-auto px-4 py-6 md:py-10' }, children);
  slot.append(wrap);
  await refresh(feed);
  return subscribeFeed(feed);
}

/** header renders the page title strip above the feed. */
function header() {
  return el('div', { class: 'mb-6' }, [
    el('h1', { class: 'text-2xl font-extrabold text-ig-text tracking-tight' }, ['Your Feed']),
    el('p', { class: 'text-ig-muted text-sm mt-0.5' }, ['What the Canagrou community is sharing right now.']),
  ]);
}

/** showSkeletons paints placeholder cards while the first load is in flight. */
function showSkeletons(feed) {
  clear(feed);
  for (let i = 0; i < SKELETON_COUNT; i++) feed.append(skeletonCard());
}

/** refresh re-lists posts + profiles and rebuilds every card in the feed. */
async function refresh(feed) {
  if (!feed.dataset.loaded) showSkeletons(feed);
  try {
    const [posts] = await Promise.all([
      baas.db.list('posts', { sort: { created_at: 'desc' }, limit: POST_LIMIT }),
      loadProfiles(),
    ]);
    feed.dataset.loaded = '1';
    clear(feed);
    if (!posts.length) {
      feed.append(emptyState());
      return;
    }
    posts.forEach((post, i) => feed.append(staggered(createPostCard(post, () => refresh(feed)), i)));
  } catch (err) {
    clear(feed);
    feed.append(errorState(feed));
    console.warn('[gallery] load failed', err && err.message);
  }
}

/** staggered applies a small entrance delay so cards cascade in. */
function staggered(card, index) {
  card.style.animationDelay = `${Math.min(index, 6) * 60}ms`;
  return card;
}

/** emptyState renders the "no posts yet" card with a contextual call to action. */
function emptyState() {
  const authed = baas.auth.isAuthed();
  const cta = el('a', {
    href: authed ? '/editor' : '/register',
    'data-link': true,
    class: 'btn btn-primary px-6 py-2.5 text-sm',
  }, [icon(authed ? 'camera' : 'plus', 'w-5 h-5'), authed ? 'Create a photo post' : 'Create an account']);
  const hint = authed
    ? 'Write something in the composer above, or capture a photo to get started.'
    : 'When people share posts, they appear here. Sign up to join the conversation.';
  return el('div', { class: 'card text-center py-16 px-8 fade-in-up' }, [
    el('div', { class: 'inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-purple-50 text-purple-500 mb-4' }, [icon('image', 'w-8 h-8')]),
    el('h2', { class: 'text-xl font-bold text-ig-text mb-1.5' }, ['Nothing here yet']),
    el('p', { class: 'text-ig-muted text-sm mb-6 max-w-xs mx-auto' }, [hint]),
    cta,
  ]);
}

/** errorState renders a friendly failure card with a Retry button. */
function errorState(feed) {
  const retry = el('button', { class: 'btn btn-secondary px-5 py-2 text-sm' }, [icon('retry', 'w-4 h-4'), 'Retry']);
  retry.addEventListener('click', () => refresh(feed));
  return el('div', { class: 'card text-center py-14 px-8 fade-in-up' }, [
    el('div', { class: 'inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-red-50 text-ig-red mb-4' }, [icon('comment', 'w-8 h-8')]),
    el('h2', { class: 'text-lg font-bold text-ig-text mb-1.5' }, ["Couldn't load the gallery"]),
    el('p', { class: 'text-ig-muted text-sm mb-6' }, ['Check your connection and try again.']),
    retry,
  ]);
}

/**
 * subscribeFeed live-refreshes the feed only when POSTS change (a new photo
 * appears / one is removed). Likes and comments are intentionally NOT subscribed
 * here: a full feed rebuild on every like/comment tears down in-progress UI
 * (open comment forms, scroll position) and feels janky — those update in-card
 * (optimistically for the actor, on next open for counts). Returns a cleanup
 * that clears the pending timer and closes the subscription.
 */
function subscribeFeed(feed) {
  let timer = 0;
  const onPostChange = () => {
    clearTimeout(timer);
    timer = setTimeout(() => refresh(feed), 400);
  };
  const sub = baas.realtime.subscribe('posts', onPostChange, (err) =>
    console.warn('[gallery] realtime posts', err && err.message),
  );
  return () => {
    clearTimeout(timer);
    sub.close();
  };
}
