// composer.js — the LinkedIn-style post composer at the top of the feed (authed
// only): an avatar, a 500-char textarea with a live colour-shifting counter, an
// optional photo attachment (preview + remove), and a Post button disabled until
// there is text or an image. On submit it ensures a profile row exists, uploads
// any photo, inserts the post, and calls onPosted(row) so the feed prepends it.

import { baas } from '../lib/baas.js';
import { ensureProfile, authorName } from '../lib/profiles.js';
import { el, clear, toast, setButtonLoading } from '../lib/dom.js';
import { avatar, icon } from './icons.js';

const MAX_LEN = 500;
const WARN_LEN = 450;
const ACCEPT = 'image/jpeg,image/png,image/webp,image/gif,video/mp4,video/webm';
const MAX_FILE = 10 * 1024 * 1024;

/**
 * createComposer builds the composer card and wires its interactions. Returns
 * the root element. onPosted (optional) receives the inserted post row so the
 * caller can optimistically prepend it without a full refetch.
 * @param onPosted callback invoked with the newly inserted post row
 */
export function createComposer(onPosted) {
  const user = baas.auth.currentUser();
  const name = (user && authorName(user.id)) || 'You';
  const state = { file: null };
  const textarea = buildTextarea();
  const counter = el('span', { class: 'text-xs text-ig-muted tabular-nums', dataset: { testid: 'composer-counter' } }, ['0/500']);
  const preview = el('div', { class: 'hidden mt-3' });
  const submit = buildSubmit();
  const photoBtn = buildPhotoBtn(state, textarea, preview, counter, submit);
  const sync = () => syncControls(textarea, counter, submit, state);
  textarea.addEventListener('input', sync);
  const card = composerCard({ name, textarea, counter, preview, photoBtn, submit });
  submit.addEventListener('click', () => submitPost({ textarea, state, preview, counter, submit, onPosted }));
  sync();
  return card;
}

/** composerCard lays out the avatar + textarea + footer (photo · counter · post). */
function composerCard({ name, textarea, counter, preview, photoBtn, submit }) {
  return el('div', { class: 'card p-4 mb-6 fade-in-up' }, [
    el('div', { class: 'flex gap-3' }, [
      avatar(name, 'w-10 h-10'),
      el('div', { class: 'flex-1 min-w-0' }, [textarea, preview]),
    ]),
    el('div', { class: 'flex items-center justify-between mt-3 pt-3 border-t border-ig-border' }, [
      el('div', { class: 'flex items-center gap-3' }, [photoBtn, counter]),
      submit,
    ]),
  ]);
}

/** buildTextarea returns the autosizing 500-char post input. */
function buildTextarea() {
  return el('textarea', {
    rows: '2',
    maxlength: String(MAX_LEN),
    placeholder: 'Share something… use #hashtags',
    class: 'w-full resize-none bg-transparent border-none text-sm text-ig-text placeholder-ig-muted focus:outline-none leading-relaxed',
    dataset: { testid: 'composer-input' },
    'aria-label': 'Write a post',
  });
}

/** buildSubmit returns the (initially disabled) gradient Post button. */
function buildSubmit() {
  return el('button', {
    type: 'button',
    class: 'btn btn-primary px-5 py-2 text-sm',
    dataset: { testid: 'composer-submit' },
  }, ['Post']);
}

/** buildPhotoBtn returns the "Add photo" button + its hidden file input. */
function buildPhotoBtn(state, textarea, preview, counter, submit) {
  const input = el('input', { type: 'file', accept: ACCEPT, class: 'hidden', dataset: { testid: 'composer-file' } });
  const btn = el('button', {
    type: 'button',
    class: 'inline-flex items-center gap-1.5 text-sm font-semibold text-ig-muted hover:text-purple-600 transition-colors',
    dataset: { testid: 'composer-photo' },
    'aria-label': 'Add a photo',
  }, [icon('image', 'w-5 h-5'), el('span', { class: 'hidden sm:inline' }, ['Photo'])]);
  btn.addEventListener('click', () => input.click());
  input.addEventListener('change', () => {
    const file = input.files[0];
    if (file) attachPhoto({ file, state, preview, counter, submit, textarea });
    input.value = '';
  });
  btn.append(input);
  return btn;
}

/** attachPhoto validates an image, shows a removable thumbnail, and enables Post. */
function attachPhoto({ file, state, preview, counter, submit, textarea }) {
  if (!ACCEPT.split(',').includes(file.type)) {
    toast('Add a JPEG, PNG, WebP, GIF, or MP4/WebM video', 'error');
    return;
  }
  if (file.size > MAX_FILE) {
    toast('Media must be smaller than 10 MB', 'error');
    return;
  }
  state.file = file;
  renderPreview({ state, preview, counter, submit, textarea });
}

/** renderPreview paints the attached image thumbnail with a remove button. */
function renderPreview({ state, preview, counter, submit, textarea }) {
  clear(preview);
  const isVid = state.file.type.startsWith('video/');
  const img = isVid
    ? el('video', { class: 'w-full max-h-64 object-cover rounded-xl border border-ig-border', controls: true, muted: true })
    : el('img', { class: 'w-full max-h-64 object-cover rounded-xl border border-ig-border', alt: 'Attached media preview' });
  img.src = URL.createObjectURL(state.file);
  img.addEventListener(isVid ? 'loadeddata' : 'load', () => URL.revokeObjectURL(img.src), { once: true });
  const remove = el('button', {
    type: 'button',
    class: 'absolute top-2 right-2 inline-flex items-center justify-center w-8 h-8 rounded-full bg-ig-text/70 text-white hover:bg-ig-text transition-colors',
    'aria-label': 'Remove photo',
    dataset: { testid: 'composer-photo-remove' },
  }, [icon('plus', 'w-5 h-5 rotate-45')]);
  remove.addEventListener('click', () => {
    state.file = null;
    preview.classList.add('hidden');
    clear(preview);
    syncControls(textarea, counter, submit, state);
  });
  preview.classList.remove('hidden');
  preview.append(el('div', { class: 'relative' }, [img, remove]));
  syncControls(textarea, counter, submit, state);
}

/** syncControls updates the counter colour and the Post button disabled state. */
function syncControls(textarea, counter, submit, state) {
  const len = textarea.value.length;
  counter.textContent = `${len}/${MAX_LEN}`;
  counter.className = counterClass(len);
  submit.disabled = textarea.value.trim().length === 0 && !state.file;
}

/** counterClass returns the colour class for the live char counter. */
function counterClass(len) {
  const base = 'text-xs tabular-nums ';
  if (len >= MAX_LEN) return base + 'text-ig-red font-semibold';
  if (len >= WARN_LEN) return base + 'text-amber-500 font-medium';
  return base + 'text-ig-muted';
}

/** submitPost uploads any photo, inserts the post, and resets the composer. */
async function submitPost(ctx) {
  const content = ctx.textarea.value.trim();
  if (content.length > MAX_LEN) {
    toast(`Posts are limited to ${MAX_LEN} characters`, 'error');
    return;
  }
  if (!content && !ctx.state.file) return;
  setButtonLoading(ctx.submit, true, 'Posting…');
  try {
    const row = await persistPost(content, ctx.state.file);
    resetComposer(ctx);
    if (ctx.onPosted) ctx.onPosted(row);
    toast('Posted to your feed! 🎉', 'success');
  } catch (err) {
    setButtonLoading(ctx.submit, false);
    toast(postError(err), 'error');
  }
}

/** persistPost ensures a profile, uploads any photo, and inserts the post row. */
async function persistPost(content, file) {
  const profile = await ensureProfile();
  const user = baas.auth.currentUser();
  if (!profile || !user) throw new Error('Please log in again to post');
  const data = { user_id: user.id };
  if (content) data.content = content;
  if (file) data.image_key = await uploadPhoto(file);
  return baas.db.insert('posts', data);
}

/** uploadPhoto stores the image under a random key and returns that key. */
async function uploadPhoto(file) {
  const ext = (file.type.split('/')[1] || 'png').replace('jpeg', 'jpg');
  const key = `${crypto.randomUUID()}.${ext}`;
  await baas.storage.upload(key, file, file.type);
  return key;
}

/** resetComposer clears the textarea, the photo, and restores the controls. */
function resetComposer(ctx) {
  ctx.textarea.value = '';
  ctx.state.file = null;
  ctx.preview.classList.add('hidden');
  clear(ctx.preview);
  setButtonLoading(ctx.submit, false);
  syncControls(ctx.textarea, ctx.counter, ctx.submit, ctx.state);
}

/** postError maps a server 409 (CHECK on content length) to a friendly message. */
function postError(err) {
  const msg = (err && err.message) || '';
  if (/409|length|500|check/i.test(msg)) return `Posts are limited to ${MAX_LEN} characters`;
  return msg || 'Could not publish your post';
}
