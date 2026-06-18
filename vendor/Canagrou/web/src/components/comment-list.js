// comment-list.js — the comments panel for one post: a scrollable list plus an
// add-comment form (when authed). Inserts via baas.db, fires the best-effort
// notifier, and re-fetches on demand. Realtime refresh is driven by the gallery
// page calling reload() on the returned handle.

import { baas } from '../lib/baas.js';
import { notifier, timeAgo } from '../../../services/index.js';
import { el, clear, escapeHtml, toast } from '../lib/dom.js';
import { authorName } from '../lib/profiles.js';

/**
 * createCommentList builds the comments panel for a post and returns
 * { element, reload } so the caller can mount it and refresh it on realtime.
 * @param postId the post these comments belong to
 */
export function createCommentList(postId) {
  const list = el('div', { class: 'px-4 py-3 space-y-3 max-h-60 overflow-y-auto' });
  const panel = el('div', { class: 'border-t border-ig-border' }, [list]);
  if (baas.auth.isAuthed()) panel.append(buildForm(postId, list));
  const reload = () => fillComments(postId, list);
  reload();
  return { element: panel, reload };
}

/** fillComments fetches a post's comments (oldest-first) and renders them. */
async function fillComments(postId, list) {
  try {
    const rows = await baas.db.list('comments', {
      where: { post_id: postId },
      sort: { created_at: 'asc' },
      limit: 200,
    });
    clear(list);
    if (!rows.length) {
      list.append(el('p', { class: 'text-ig-muted text-sm text-center py-2' }, ['No comments yet. Be the first!']));
      return;
    }
    for (const row of rows) list.append(commentRow(row));
  } catch (err) {
    clear(list);
    list.append(el('p', { class: 'text-ig-red text-sm text-center' }, ['Failed to load comments.']));
    console.warn('[comments] load failed', err && err.message);
  }
}

/** commentRow renders one comment with an avatar bubble, author, and text. */
function commentRow(row) {
  const name = authorName(row.user_id);
  const avatar = el(
    'div',
    { class: 'w-7 h-7 rounded-full bg-gradient-to-br from-yellow-400 via-pink-500 to-purple-600 p-[2px] flex-shrink-0' },
    [
      el('div', { class: 'w-full h-full rounded-full bg-white flex items-center justify-center' }, [
        el('span', { class: 'text-[10px] font-semibold text-ig-text' }, [name.charAt(0).toUpperCase()]),
      ]),
    ],
  );
  const body = el('div', { class: 'flex-1 min-w-0' }, [
    el('span', { class: 'text-sm', html: `<b>${escapeHtml(name)}</b> ${escapeHtml(row.content)}` }),
    el('p', { class: 'text-ig-muted text-xs mt-0.5' }, [timeAgo(row.created_at)]),
  ]);
  return el('div', { class: 'flex gap-2.5 items-start' }, [avatar, body]);
}

/** buildForm returns the add-comment form, wired to submit a new comment. */
function buildForm(postId, list) {
  const input = el('input', {
    type: 'text',
    name: 'content',
    placeholder: 'Add a comment…',
    maxlength: '1000',
    autocomplete: 'off',
    class: 'flex-1 bg-transparent border-none text-sm text-ig-text placeholder-ig-muted focus:outline-none py-2',
  });
  const submit = el('button', {
    type: 'submit',
    class: 'text-ig-blue hover:text-blue-700 text-sm font-semibold transition-colors',
  });
  submit.textContent = 'Post';
  const form = el('form', { class: 'px-4 py-3 border-t border-ig-border flex items-center gap-2' }, [input, submit]);
  form.addEventListener('submit', (e) => submitComment(e, postId, input, submit, list));
  return form;
}

/** submitComment inserts the comment, refreshes the list, and notifies. */
async function submitComment(event, postId, input, submit, list) {
  event.preventDefault();
  const content = input.value.trim();
  if (!content) return;
  submit.disabled = true;
  try {
    const user = baas.auth.currentUser();
    await baas.db.insert('comments', { user_id: user.id, post_id: postId, content });
    input.value = '';
    await fillComments(postId, list);
    list.scrollTop = list.scrollHeight;
    notifier.commentNotify({ baas, postId, content });
  } catch (err) {
    toast(err && err.message ? err.message : 'Failed to post comment', 'error');
  } finally {
    submit.disabled = false;
  }
}
