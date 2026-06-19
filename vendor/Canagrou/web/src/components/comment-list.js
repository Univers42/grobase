// comment-list.js — the comments panel for one post: a scrollable list plus an
// add-comment form (when authed). New comments append optimistically (dimmed
// "sending" state, input disabled) and confirm or revert with a toast. Inserts
// via baas.db and fires the best-effort notifier. The parent post-card passes an
// onCount callback so the "view all N" preview stays in sync.

import { baas } from '../lib/baas.js';
import { notifier, timeAgo } from '../../../services/index.js';
import { el, clear, escapeHtml, toast, spinner } from '../lib/dom.js';
import { authorName } from '../lib/profiles.js';
import { avatar } from './icons.js';

/**
 * createCommentList builds the comments panel for a post and returns
 * { element, reload }. onCount (optional) is called with the comment count.
 * @param postId  the post these comments belong to
 * @param onCount callback receiving the current comment count
 */
export function createCommentList(postId, onCount) {
  const list = el('div', { class: 'px-4 py-3 space-y-3 max-h-72 overflow-y-auto' });
  const panel = el('div', { class: 'border-t border-ig-border bg-ig-bg/40' }, [list]);
  if (baas.auth.isAuthed()) panel.append(buildForm(postId, list, onCount));
  const reload = () => fillComments(postId, list, onCount);
  reload();
  return { element: panel, reload };
}

/** fillComments fetches a post's comments (oldest-first) and renders them. */
async function fillComments(postId, list, onCount) {
  list.replaceChildren(loadingRow());
  try {
    const rows = await baas.db.list('comments', { where: { post_id: postId }, sort: { created_at: 'asc' }, limit: 200 });
    if (onCount) onCount(rows.length);
    clear(list);
    if (!rows.length) {
      list.append(el('p', { class: 'text-ig-muted text-sm text-center py-3' }, ['No comments yet. Be the first! 💬']));
      return;
    }
    for (const row of rows) list.append(commentRow(row));
  } catch (err) {
    clear(list);
    list.append(el('p', { class: 'text-ig-red text-sm text-center py-2' }, ['Failed to load comments.']));
    console.warn('[comments] load failed', err && err.message);
  }
}

/** loadingRow renders a centered spinner while comments fetch. */
function loadingRow() {
  return el('div', { class: 'flex justify-center py-3 text-purple-500' }, [spinner('spinner')]);
}

/** commentRow renders one comment with an initials avatar, author, and text. */
function commentRow(row, pending = false) {
  const name = authorName(row.user_id);
  const body = el('div', { class: 'flex-1 min-w-0' }, [
    el('p', { class: 'text-sm leading-snug', html: `<span class="font-semibold">${escapeHtml(name)}</span> ${escapeHtml(row.content)}` }),
    el('p', { class: 'text-ig-muted text-[11px] mt-0.5' }, [pending ? 'sending…' : timeAgo(row.created_at)]),
  ]);
  return el('div', { class: `flex gap-2.5 items-start ${pending ? 'comment-pending' : ''}` }, [avatar(name, 'w-7 h-7'), body]);
}

/** buildForm returns the add-comment form, wired to submit a new comment. */
function buildForm(postId, list, onCount) {
  const input = el('input', {
    type: 'text',
    name: 'content',
    placeholder: 'Add a comment…',
    maxlength: '1000',
    autocomplete: 'off',
    class: 'flex-1 bg-transparent border-none text-sm text-ig-text placeholder-ig-muted focus:outline-none py-2',
    dataset: { testid: 'comment-input' },
  });
  const submit = el('button', { type: 'submit', class: 'text-purple-600 hover:text-purple-700 text-sm font-semibold transition-colors disabled:opacity-40', dataset: { testid: 'comment-submit' } }, ['Post']);
  const form = el('form', { class: 'px-4 py-2.5 border-t border-ig-border flex items-center gap-2 bg-white' }, [input, submit]);
  form.addEventListener('submit', (e) => submitComment(e, { postId, input, submit, list, onCount }));
  return form;
}

/** submitComment optimistically appends, confirms, or reverts with a toast. */
async function submitComment(event, ctx) {
  event.preventDefault();
  const content = ctx.input.value.trim();
  if (!content) return;
  const user = baas.auth.currentUser();
  const optimistic = commentRow({ user_id: user.id, content }, true);
  ctx.list.append(optimistic);
  ctx.list.scrollTop = ctx.list.scrollHeight;
  setSending(ctx, true);
  try {
    await baas.db.insert('comments', { user_id: user.id, post_id: ctx.postId, content });
    ctx.input.value = '';
    await fillComments(ctx.postId, ctx.list, ctx.onCount);
    ctx.list.scrollTop = ctx.list.scrollHeight;
    notifier.commentNotify({ baas, postId: ctx.postId, content });
  } catch (err) {
    optimistic.remove();
    toast(err && err.message ? err.message : 'Failed to post comment', 'error');
  } finally {
    setSending(ctx, false);
  }
}

/** setSending disables the input + submit while a comment is in flight. */
function setSending(ctx, sending) {
  ctx.input.disabled = sending;
  ctx.submit.disabled = sending;
  ctx.submit.textContent = sending ? 'Posting…' : 'Post';
}
