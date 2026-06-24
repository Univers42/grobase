// settings.js — profile settings (guarded route). Loads the current user's
// profile row, lets them change their username (with inline validation + a
// loading/saved button) and toggle the notify_comments email preference (a real
// switch showing a saving indicator + "Saved"), persisting via baas.db.update.

import { baas } from '../lib/baas.js';
import { el, toast, setButtonLoading } from '../lib/dom.js';
import { icon, avatar } from '../components/icons.js';
import { authorName } from '../lib/profiles.js';
import { validateUsername } from '../lib/validate.js';

/**
 * render loads the profile and mounts the username + notifications cards. The
 * default export the router calls (route is guarded — user is authenticated).
 * @param slot the content container provided by the router
 */
export default async function render(slot) {
  const user = baas.auth.currentUser();
  const profile = await loadProfile(user, slot);
  if (!profile) return;
  slot.append(el('div', { class: 'max-w-[620px] mx-auto px-4 py-6 md:py-10 space-y-6' }, [
    el('h1', { class: 'text-2xl font-extrabold text-ig-text tracking-tight' }, ['Settings']),
    identityHeader(profile, user),
    usernameSection(profile),
    notificationsSection(profile),
  ]));
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

/** identityHeader shows the avatar + name/email banner at the top of settings. */
function identityHeader(profile, user) {
  const name = profile.username || authorName(user.id);
  return el('section', { class: 'card p-5 flex items-center gap-4' }, [
    avatar(name, 'w-14 h-14'),
    el('div', { class: 'min-w-0' }, [
      el('p', { class: 'text-lg font-bold text-ig-text truncate' }, [name]),
      el('p', { class: 'text-sm text-ig-muted truncate' }, [user.email || '']),
    ]),
  ]);
}

/** usernameSection builds the change-username card and its save handler. */
function usernameSection(profile) {
  const input = el('input', { type: 'text', value: profile.username || '', maxlength: '20', class: 'input', dataset: { testid: 'username-input' } });
  const hint = el('p', { class: 'field-hint' });
  const save = el('button', { type: 'submit', class: 'btn btn-primary px-6 py-2 text-sm mt-3' }, ['Save']);
  const form = el('form', { class: 'space-y-1', novalidate: true }, [
    el('label', { class: 'block text-sm font-semibold text-ig-text mb-1.5' }, ['Username']),
    input, hint, save,
  ]);
  input.addEventListener('input', () => { hint.textContent = ''; hint.className = 'field-hint'; });
  form.addEventListener('submit', (e) => saveUsername(e, { profile, input, hint, save }));
  return sectionCard('Profile', 'settings', [form]);
}

/** saveUsername validates then persists a new username with button feedback. */
async function saveUsername(event, ui) {
  event.preventDefault();
  const username = ui.input.value.trim();
  const err = validateUsername(username);
  if (err) {
    ui.hint.className = 'field-hint error';
    ui.hint.textContent = err;
    return;
  }
  setButtonLoading(ui.save, true, 'Saving…');
  try {
    await baas.db.update('profiles', { username }, { id: ui.profile.id });
    ui.profile.username = username;
    confirmSaved(ui.save, 'Saved');
    toast('Username updated', 'success');
  } catch (err) {
    setButtonLoading(ui.save, false);
    toast(err && err.message ? err.message : 'Update failed', 'error');
  }
}

/** confirmSaved flashes a green "Saved ✓" on a button then restores it. */
function confirmSaved(btn, label) {
  setButtonLoading(btn, false);
  const original = btn.innerHTML;
  btn.innerHTML = '';
  btn.style.background = 'linear-gradient(120deg,#059669,#047857)';
  btn.append(label);
  setTimeout(() => { btn.innerHTML = original; btn.style.background = ''; }, 1600);
}

/** notificationsSection builds the comment-notification toggle card. */
function notificationsSection(profile) {
  const status = el('span', { class: 'text-xs text-ig-muted ml-auto min-w-[3.5rem] text-right' }, [profile.notify_comments ? 'On' : 'Off']);
  const sw = toggleSwitch(Boolean(profile.notify_comments), (val) => saveNotify(profile, sw, status, val));
  const row = el('label', { class: 'flex items-center gap-3 cursor-pointer' }, [
    el('div', { class: 'flex-1' }, [
      el('p', { class: 'text-sm font-semibold text-ig-text' }, ['Comment notifications']),
      el('p', { class: 'text-ig-muted text-sm' }, ['Email me when someone comments on my photos.']),
    ]),
    status,
    sw.element,
  ]);
  return sectionCard('Email notifications', 'comment', [row]);
}

/** toggleSwitch builds an accessible switch; onChange receives the new boolean. */
function toggleSwitch(checked, onChange) {
  const knob = el('span', { class: 'absolute top-0.5 left-0.5 w-5 h-5 bg-white rounded-full shadow transition-transform' });
  const element = el('button', {
    type: 'button',
    role: 'switch',
    'aria-checked': String(checked),
    class: `relative w-11 h-6 rounded-full transition-colors ${checked ? 'bg-purple-600' : 'bg-ig-border'}`,
    dataset: { testid: 'notify-toggle' },
  }, [knob]);
  const paint = (on) => {
    element.setAttribute('aria-checked', String(on));
    element.className = `relative w-11 h-6 rounded-full transition-colors ${on ? 'bg-purple-600' : 'bg-ig-border'}`;
    knob.style.transform = on ? 'translateX(20px)' : 'translateX(0)';
  };
  paint(checked);
  element.addEventListener('click', () => onChange(element.getAttribute('aria-checked') !== 'true'));
  return { element, paint };
}

/** saveNotify persists the preference, showing a saving→saved state on the row. */
async function saveNotify(profile, sw, status, value) {
  sw.paint(value);
  status.textContent = 'Saving…';
  try {
    await baas.db.update('profiles', { notify_comments: value }, { id: profile.id });
    profile.notify_comments = value;
    status.textContent = 'Saved ✓';
    setTimeout(() => (status.textContent = value ? 'On' : 'Off'), 1400);
  } catch (err) {
    sw.paint(!value);
    status.textContent = !value ? 'On' : 'Off';
    toast(err && err.message ? err.message : 'Update failed', 'error');
  }
}

/** sectionCard wraps a settings group in a titled card with an icon. */
function sectionCard(title, glyph, children) {
  return el('section', { class: 'card p-6' }, [
    el('div', { class: 'flex items-center gap-2 mb-4 text-ig-text' }, [
      el('span', { class: 'text-purple-500' }, [icon(glyph, 'w-5 h-5')]),
      el('h2', { class: 'text-base font-bold' }, [title]),
    ]),
    ...children,
  ]);
}
