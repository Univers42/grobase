// tag.js — the hashtag feed at /tag/:tag. Renders a "#<tag>" header and the posts
// whose content contains that hashtag (newest first), reusing the shared post
// feed (and thus post-card, with like/comment/share). Public route — no auth
// required. The tag comes from the router as a decoded param.

import { baas } from '../lib/baas.js';
import { el } from '../lib/dom.js';
import { fillPostFeed } from '../components/post-feed.js';
import { icon } from '../components/icons.js';

const POST_LIMIT = 50;

/**
 * render mounts the hashtag feed for params.tag. The router passes the decoded
 * param; an absent tag falls back to home.
 * @param slot   the content container provided by the router
 * @param params { tag } from the /tag/:tag route
 */
export default async function render(slot, params) {
  const tag = (params && params.tag) || '';
  if (!tag) {
    window.canagrouNavigate('/', true);
    return;
  }
  const feed = el('div', { class: 'space-y-6', dataset: { testid: 'gallery-feed' } });
  slot.append(el('div', { class: 'max-w-[500px] mx-auto px-4 py-6 md:py-10' }, [header(tag), feed]));
  await fillPostFeed(feed, () => loadTagPosts(tag), `No posts tagged #${tag} yet.`);
}

/** header renders the #tag title strip + a back-to-feed link. */
function header(tag) {
  return el('div', { class: 'mb-6' }, [
    el('a', { href: '/', 'data-link': true, class: 'inline-flex items-center gap-1 text-sm font-semibold text-purple-600 hover:text-purple-700 mb-3' }, [icon('home', 'w-4 h-4'), 'Back to feed']),
    el('h1', { class: 'text-2xl font-extrabold text-ig-text tracking-tight' }, [`#${tag}`]),
    el('p', { class: 'text-ig-muted text-sm mt-0.5' }, ['Everything the community tagged with this hashtag.']),
  ]);
}

/** loadTagPosts lists posts whose content ILIKEs the #tag, newest first. */
function loadTagPosts(tag) {
  return baas.db.list('posts', {
    filter: { content: { $ilike: `%#${tag}%` } },
    sort: { created_at: 'desc' },
    limit: POST_LIMIT,
  });
}
