// share-composer.js — the inline repost panel opened by a post's Share button.
// A small textarea for optional commentary (≤500, also #hashtag-aware) plus a
// Repost button that inserts a new post carrying shared_post_id = the original's
// id. Toggles open/closed on repeated Share clicks; reverts + toasts on error.

import { baas } from '../lib/baas.js';
import { ensureProfile } from '../lib/profiles.js';
import { el, toast, setButtonLoading } from '../lib/dom.js';

const MAX_LEN = 500;

/**
 * openShareComposer mounts (once) and toggles an inline repost panel directly
 * after the post card. Requires auth; routes guests to login.
 * @param post     the post being reposted
 * @param btn      the Share button (panel is inserted after its card)
 * @param onChange optional callback to refresh the feed after a repost
 */
export function openShareComposer(post, btn, onChange) {
  if (!baas.auth.isAuthed()) {
    toast('Log in to repost', 'info');
    window.canagrouNavigate('/login');
    return;
  }
  const card = btn.closest('[data-testid=post-card]');
  if (!card) return;
  let panel = card.nextElementSibling;
  if (!panel || panel.dataset.shareFor !== String(post.id)) {
    panel = buildPanel(post, onChange);
    card.after(panel);
    return;
  }
  panel.classList.toggle('hidden');
}

/** buildPanel constructs the repost composer card bound to the original post. */
function buildPanel(post, onChange) {
  const input = el('textarea', {
    rows: '2',
    maxlength: String(MAX_LEN),
    placeholder: 'Add a thought… (optional) — #hashtags work too',
    class: 'w-full resize-none input text-sm',
    dataset: { testid: 'share-input' },
    'aria-label': 'Repost commentary',
  });
  const submit = el('button', { type: 'button', class: 'btn btn-primary px-5 py-2 text-sm', dataset: { testid: 'share-submit' } }, ['Repost']);
  const cancel = el('button', { type: 'button', class: 'btn btn-ghost px-4 py-2 text-sm' }, ['Cancel']);
  const panel = el('div', { class: 'card p-4 -mt-3 mb-6 border-purple-200 fade-in-up', dataset: { shareFor: String(post.id) } }, [
    el('p', { class: 'text-xs font-semibold text-ig-muted mb-2' }, ['🔁 Reposting to your feed']),
    input,
    el('div', { class: 'flex items-center justify-end gap-2 mt-3' }, [cancel, submit]),
  ]);
  cancel.addEventListener('click', () => panel.classList.add('hidden'));
  submit.addEventListener('click', () => doRepost({ post, input, submit, panel, onChange }));
  return panel;
}

/** doRepost inserts the repost row, then refreshes the feed or prepends locally. */
async function doRepost(ctx) {
  const content = ctx.input.value.trim();
  if (content.length > MAX_LEN) {
    toast(`Commentary is limited to ${MAX_LEN} characters`, 'error');
    return;
  }
  setButtonLoading(ctx.submit, true, 'Reposting…');
  try {
    const profile = await ensureProfile();
    const user = baas.auth.currentUser();
    if (!profile || !user) throw new Error('Please log in again to repost');
    const data = { user_id: user.id, shared_post_id: ctx.post.id };
    if (content) data.content = content;
    const row = await baas.db.insert('posts', data);
    ctx.panel.remove();
    toast('Reposted to your feed! 🔁', 'success');
    if (ctx.onChange) ctx.onChange(row);
  } catch (err) {
    setButtonLoading(ctx.submit, false);
    toast(err && err.message ? err.message : 'Could not repost', 'error');
  }
}
