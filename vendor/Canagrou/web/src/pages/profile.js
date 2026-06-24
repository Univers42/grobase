// profile.js — a user's profile at /profile/:userId. A header (large avatar,
// username, member-since, posts/likes-received stats) and three triggerable tabs:
// Posts (their posts), About (profile facts), Likes (posts they liked). Tabs swap
// content in-place without a reload. Public route. The userId is a router param.

import { baas } from '../lib/baas.js';
import { el, clear } from '../lib/dom.js';
import { authorName, loadProfiles } from '../lib/profiles.js';
import { avatar } from '../components/icons.js';
import { fillPostFeed } from '../components/post-feed.js';
import { renderAboutTab } from '../components/profile-about.js';
import { loadUserStats, listUserPosts, listLikedPosts } from '../components/profile-data.js';

/**
 * render mounts the profile for params.userId: header + tabbed body. The router
 * passes the decoded param; an absent id falls back home.
 * @param slot   the content container provided by the router
 * @param params { userId } from the /profile/:userId route
 */
export default async function render(slot, params) {
  const userId = (params && params.userId) || '';
  if (!userId) {
    window.canagrouNavigate('/', true);
    return;
  }
  await loadProfiles();
  const profile = await fetchProfile(userId);
  const body = el('div', { class: 'mt-6' });
  const tabs = tabBar(userId, profile, body);
  slot.append(el('div', { class: 'max-w-[560px] mx-auto px-4 py-6 md:py-10' }, [
    profileHeader(userId, profile),
    tabs.element,
    body,
  ]));
  tabs.select('posts');
}

/** fetchProfile loads the profile row for a user id, or null when absent. */
async function fetchProfile(userId) {
  try {
    const rows = await baas.db.list('profiles', { where: { id: userId }, limit: 1 });
    return rows[0] || null;
  } catch (err) {
    console.warn('[profile] load failed', err && err.message);
    return null;
  }
}

/** profileHeader renders the avatar, name, member-since, and the stat row. */
function profileHeader(userId, profile) {
  const name = (profile && profile.username) || authorName(userId);
  const since = profile && profile.created_at ? new Date(profile.created_at).toLocaleDateString(undefined, { year: 'numeric', month: 'long' }) : '—';
  const posts = el('span', { class: 'font-bold text-ig-text', dataset: { testid: 'stat-posts' } }, ['—']);
  const likes = el('span', { class: 'font-bold text-ig-text', dataset: { testid: 'stat-likes' } }, ['—']);
  fillStats(userId, posts, likes);
  return el('section', { class: 'card p-6 flex flex-col sm:flex-row items-center gap-5 fade-in-up' }, [
    avatar(name, 'w-20 h-20'),
    el('div', { class: 'flex-1 min-w-0 text-center sm:text-left' }, [
      el('h1', { class: 'text-2xl font-extrabold text-ig-text tracking-tight truncate' }, [name]),
      el('p', { class: 'text-ig-muted text-sm mt-0.5' }, [`Member since ${since}`]),
      el('div', { class: 'flex items-center justify-center sm:justify-start gap-6 mt-3 text-sm text-ig-muted' }, [
        el('span', {}, [posts, ' posts']),
        el('span', {}, [likes, ' likes received']),
      ]),
    ]),
  ]);
}

/** fillStats computes posts authored + total likes received and writes them. */
async function fillStats(userId, postsEl, likesEl) {
  try {
    const stats = await loadUserStats(userId);
    postsEl.textContent = String(stats.posts);
    likesEl.textContent = String(stats.likesReceived);
  } catch (err) {
    console.warn('[profile] stats failed', err && err.message);
  }
}

/** tabBar builds the tab strip and returns { element, select(name) }. */
function tabBar(userId, profile, body) {
  const defs = [
    { name: 'posts', label: 'Posts', testid: 'profile-tab-posts' },
    { name: 'about', label: 'About', testid: 'profile-tab-about' },
    { name: 'likes', label: 'Likes', testid: 'profile-tab-likes' },
  ];
  const buttons = new Map();
  const select = (name) => activate(name, buttons, body, { userId, profile });
  const element = el('div', { class: 'flex items-center gap-1 mt-6 p-1 card', role: 'tablist' }, defs.map((d) => {
    const btn = tabButton(d, () => select(d.name));
    buttons.set(d.name, btn);
    return btn;
  }));
  return { element, select };
}

/** tabButton builds one tab trigger (inactive styling by default). */
function tabButton(def, onClick) {
  return el('button', {
    type: 'button',
    role: 'tab',
    class: tabClass(false),
    dataset: { testid: def.testid, tab: def.name },
    onClick,
  }, [def.label]);
}

/** activate switches the active tab styling and renders its content into body. */
function activate(name, buttons, body, ctx) {
  for (const [key, btn] of buttons) {
    const on = key === name;
    btn.className = tabClass(on);
    btn.setAttribute('aria-selected', String(on));
  }
  clear(body);
  if (name === 'about') body.append(renderAboutTab(ctx.userId, ctx.profile));
  else renderPostsTab(name, ctx.userId, body);
}

/** renderPostsTab fills the Posts or Likes tab with the shared post feed. */
function renderPostsTab(name, userId, body) {
  const feed = el('div', { class: 'space-y-6', dataset: { testid: 'gallery-feed' } });
  body.append(feed);
  if (name === 'likes') {
    fillPostFeed(feed, () => listLikedPosts(userId), 'No liked posts yet.', () => renderPostsTab('likes', userId, body));
    return;
  }
  fillPostFeed(feed, () => listUserPosts(userId), 'No posts yet.', () => renderPostsTab('posts', userId, body));
}

/** tabClass returns active/inactive styling for a profile tab. */
function tabClass(active) {
  const base = 'flex-1 py-2 px-4 text-sm font-semibold rounded-lg transition-all ';
  return base + (active ? 'bg-gradient-to-r from-purple-600 to-pink-500 text-white shadow' : 'text-ig-muted hover:text-ig-text hover:bg-ig-bg');
}
