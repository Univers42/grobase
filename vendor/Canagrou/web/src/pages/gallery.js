// gallery.js — the public feed page. Loads the latest posts (newest first),
// fills the id→username profile cache, renders a post-card per post, and
// subscribes to realtime changes on posts/likes/comments — refreshing the feed
// when any of them changes (a full re-list is simplest and correct here).

import { baas } from '../lib/baas.js';
import { el, clear, toast } from '../lib/dom.js';
import { loadProfiles } from '../lib/profiles.js';
import { createPostCard } from '../components/post-card.js';

const POST_LIMIT = 30;

/**
 * render mounts the gallery into the slot: a centered feed column that lists
 * posts and live-refreshes on realtime events. Returns a cleanup function the
 * router calls on navigation to close the realtime subscriptions.
 * @param slot the content container provided by the router
 * @returns cleanup function closing realtime subscriptions
 */
export default async function render(slot) {
  const feed = el('div', { id: 'gallery-feed', class: 'space-y-4' });
  const wrap = el('div', { class: 'max-w-[470px] mx-auto px-4 py-6 md:py-8' }, [feed]);
  slot.append(wrap);
  await refresh(feed);
  return subscribeFeed(feed);
}

/** refresh re-lists posts + profiles and rebuilds every card in the feed. */
async function refresh(feed) {
  try {
    const [posts] = await Promise.all([
      baas.db.list('posts', { sort: { created_at: 'desc' }, limit: POST_LIMIT }),
      loadProfiles(),
    ]);
    clear(feed);
    if (!posts.length) {
      feed.append(emptyState());
      return;
    }
    for (const post of posts) feed.append(createPostCard(post));
  } catch (err) {
    clear(feed);
    feed.append(el('p', { class: 'text-ig-red text-sm text-center py-8' }, ['Failed to load the gallery.']));
    toast(err && err.message ? err.message : 'Gallery load failed', 'error');
  }
}

/** emptyState renders the "no posts yet" card with a contextual call to action. */
function emptyState() {
  const authed = baas.auth.isAuthed();
  const cta = el('a', {
    href: authed ? '/editor' : '/register',
    'data-link': true,
    class: 'inline-flex items-center gap-2 bg-ig-blue hover:bg-blue-600 text-white px-6 py-2.5 rounded-lg transition-colors font-semibold text-sm',
  });
  cta.textContent = authed ? 'Share your first photo' : 'Create an account';
  return el('div', { class: 'bg-white border border-ig-border rounded-lg text-center py-16 px-8' }, [
    el('h2', { class: 'text-2xl font-light text-ig-text mb-2' }, ['Share Photos']),
    el('p', { class: 'text-ig-muted text-sm mb-6' }, ["When people share photos, they'll appear here."]),
    cta,
  ]);
}

/**
 * subscribeFeed opens realtime subscriptions on posts/likes/comments, debouncing
 * a feed refresh on any event. Returns a cleanup function that clears the
 * pending refresh timer and closes every subscription.
 */
function subscribeFeed(feed) {
  let timer = 0;
  const onChange = () => {
    clearTimeout(timer);
    timer = setTimeout(() => refresh(feed), 400);
  };
  const subs = ['posts', 'likes', 'comments'].map((table) =>
    baas.realtime.subscribe(table, onChange, (err) => console.warn(`[gallery] realtime ${table}`, err && err.message)),
  );
  return () => {
    clearTimeout(timer);
    for (const sub of subs) sub.close();
  };
}
