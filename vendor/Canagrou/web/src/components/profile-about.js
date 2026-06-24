// profile-about.js — the About tab of a profile: username, comment-notification
// preference, and account-created date as a clean fact list. A small presentation
// component; takes the already-loaded profile row (or null) and the user id.

import { el } from '../lib/dom.js';
import { authorName } from '../lib/profiles.js';
import { icon } from './icons.js';

/**
 * renderAboutTab returns the About panel for a profile.
 * @param userId  the profile owner's id (for the username fallback)
 * @param profile the profile row {username,notify_comments,created_at} or null
 */
export function renderAboutTab(userId, profile) {
  const name = (profile && profile.username) || authorName(userId);
  const created = profile && profile.created_at ? new Date(profile.created_at).toLocaleString() : 'Unknown';
  const notify = profile && profile.notify_comments ? 'On' : 'Off';
  return el('div', { class: 'card p-6 fade-in-up space-y-1' }, [
    factRow('settings', 'Username', name),
    factRow('comment', 'Comment notifications', notify),
    factRow('home', 'Member since', created),
  ]);
}

/** factRow renders one labelled fact line with an icon. */
function factRow(glyph, label, value) {
  return el('div', { class: 'flex items-center gap-3 py-2.5 border-b border-ig-border last:border-0' }, [
    el('span', { class: 'text-purple-500' }, [icon(glyph, 'w-5 h-5')]),
    el('div', { class: 'flex-1 min-w-0' }, [
      el('p', { class: 'text-xs text-ig-muted uppercase tracking-wide' }, [label]),
      el('p', { class: 'text-sm font-semibold text-ig-text truncate' }, [value]),
    ]),
  ]);
}
