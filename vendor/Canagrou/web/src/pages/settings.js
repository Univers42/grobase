// settings.js — profile settings (guarded route). Loads the current user's
// profile row, lets them change their username and toggle the notify_comments
// email preference, persisting each via baas.db.update on the profiles table.

import { baas } from '../lib/baas.js';
import { el, toast } from '../lib/dom.js';

/**
 * render loads the profile and mounts the username + notifications forms. The
 * default export the router calls (route is guarded — user is authenticated).
 * @param slot the content container provided by the router
 */
export default async function render(slot) {
  const user = baas.auth.currentUser();
  const profile = await loadProfile(user, slot);
  if (!profile) return;
  slot.append(
    el('div', { class: 'max-w-[600px] mx-auto px-4 py-6 md:py-8 space-y-8' }, [
      el('h1', { class: 'text-2xl font-bold text-ig-text' }, ['Settings']),
      usernameSection(profile),
      notificationsSection(profile),
    ]),
  );
}

/** loadProfile fetches the current user's profile row, erroring into the slot. */
async function loadProfile(user, slot) {
  try {
    const rows = await baas.db.list('profiles', { where: { id: user.id }, limit: 1 });
    if (!rows[0]) throw new Error('Profile not found');
    return rows[0];
  } catch (err) {
    slot.append(el('p', { class: 'text-ig-red text-sm text-center py-8' }, ['Failed to load your profile.']));
    toast(err && err.message ? err.message : 'Profile load failed', 'error');
    return null;
  }
}

/** usernameSection builds the change-username card and its save handler. */
function usernameSection(profile) {
  const input = el('input', {
    type: 'text',
    value: profile.username || '',
    required: true,
    minlength: '3',
    maxlength: '20',
    class: 'w-full px-3 py-[7px] rounded-[3px] bg-white border border-ig-border text-ig-text text-sm focus:outline-none focus:border-gray-400',
  });
  const save = el('button', { type: 'submit', class: 'mt-3 px-6 py-[5px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 disabled:opacity-50 transition-colors' }, ['Submit']);
  const form = el('form', { class: 'space-y-2' }, [
    el('label', { class: 'text-sm font-semibold text-ig-text' }, ['Username']),
    input,
    save,
  ]);
  form.addEventListener('submit', (e) => saveUsername(e, profile, input, save));
  return el('section', { class: 'bg-white border border-ig-border rounded-lg p-6' }, [form]);
}

/** saveUsername persists a new username to the profile row. */
async function saveUsername(event, profile, input, save) {
  event.preventDefault();
  const username = input.value.trim();
  if (username.length < 3) {
    toast('Username must be at least 3 characters', 'error');
    return;
  }
  save.disabled = true;
  try {
    await baas.db.update('profiles', { username }, { id: profile.id });
    profile.username = username;
    toast('Username updated', 'success');
  } catch (err) {
    toast(err && err.message ? err.message : 'Update failed', 'error');
  } finally {
    save.disabled = false;
  }
}

/** notificationsSection builds the comment-notification toggle card. */
function notificationsSection(profile) {
  const checkbox = el('input', {
    type: 'checkbox',
    class: 'mt-1 w-4 h-4 rounded border-ig-border text-ig-blue focus:ring-ig-blue',
  });
  checkbox.checked = Boolean(profile.notify_comments);
  checkbox.addEventListener('change', () => saveNotify(profile, checkbox));
  const label = el('label', { class: 'flex items-start gap-3 cursor-pointer' }, [
    checkbox,
    el('div', {}, [
      el('span', { class: 'text-sm font-semibold text-ig-text' }, ['Comment notifications']),
      el('p', { class: 'text-ig-muted text-sm' }, ['Receive an email when someone comments on your photos.']),
    ]),
  ]);
  return el('section', { class: 'bg-white border border-ig-border rounded-lg p-6' }, [
    el('h2', { class: 'text-lg font-semibold text-ig-text mb-4' }, ['Email Notifications']),
    label,
  ]);
}

/** saveNotify persists the comment-notification preference on toggle. */
async function saveNotify(profile, checkbox) {
  const value = checkbox.checked;
  try {
    await baas.db.update('profiles', { notify_comments: value }, { id: profile.id });
    profile.notify_comments = value;
    toast('Preference saved', 'success');
  } catch (err) {
    checkbox.checked = !value;
    toast(err && err.message ? err.message : 'Update failed', 'error');
  }
}
