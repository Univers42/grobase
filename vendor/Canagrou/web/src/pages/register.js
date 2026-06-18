// register.js — sign-up page. Calls baas.auth.signUp (email/password/username),
// then inserts the matching profiles row (id = GoTrue sub, notify_comments=true),
// then routes home. Validates that the two password fields match client-side.

import { baas } from '../lib/baas.js';
import { el } from '../lib/dom.js';
import { authCard, field, submitButton, showError, linkRow } from '../components/auth-form.js';

/**
 * render mounts the registration form. The default export the router calls; on
 * success it creates the profile and navigates to the gallery.
 * @param slot the content container provided by the router
 */
export default function render(slot) {
  const ui = {
    email: field({ type: 'email', name: 'email', placeholder: 'Email', required: true, autocomplete: 'email' }),
    username: field({ type: 'text', name: 'username', placeholder: 'Username', required: true, minlength: '3', maxlength: '20', pattern: '[a-zA-Z0-9_]+' }),
    password: field({ type: 'password', name: 'password', placeholder: 'Password', required: true, minlength: '8', autocomplete: 'new-password' }),
    confirm: field({ type: 'password', name: 'confirm', placeholder: 'Confirm Password', required: true, autocomplete: 'new-password' }),
  };
  ui.submit = submitButton('Sign up');
  ui.form = el('form', { class: 'space-y-2' }, [ui.email, ui.username, ui.password, ui.confirm, ui.submit]);
  ui.form.addEventListener('submit', (e) => onSubmit(e, ui));
  slot.append(el('div', {}, [
    authCard([ui.form], 'Sign up to capture, create and share moments.'),
    linkRow('Have an account?', '/login', 'Log in'),
  ]));
}

/** onSubmit validates inputs, signs up, creates the profile, and routes home. */
async function onSubmit(event, ui) {
  event.preventDefault();
  if (ui.password.value !== ui.confirm.value) {
    showError(ui.form, 'Passwords do not match');
    return;
  }
  ui.submit.disabled = true;
  try {
    const resp = await baas.auth.signUp({
      email: ui.email.value.trim(),
      password: ui.password.value,
      username: ui.username.value.trim(),
    });
    await createProfile(resp, ui.username.value.trim());
    window.canagrouNavigate('/');
  } catch (err) {
    showError(ui.form, err && err.message ? err.message : 'Registration failed');
  } finally {
    ui.submit.disabled = false;
  }
}

/** createProfile inserts the profiles row keyed by the new user's GoTrue sub. */
async function createProfile(resp, username) {
  const userId = (resp && resp.user && resp.user.id) || baas.auth.currentUser()?.id;
  if (!userId) throw new Error('Sign-up succeeded but no user id was returned');
  await baas.db.insert('profiles', { id: userId, username, notify_comments: true });
}
