// login.js — sign-in page. Uses baas.auth.signInWithPassword (email + password —
// the proven lib authenticates by email, not username) then routes home.

import { baas } from '../lib/baas.js';
import { el } from '../lib/dom.js';
import { authCard, field, submitButton, showError, linkRow } from '../components/auth-form.js';

/**
 * render mounts the login form into the slot. The default export the router
 * calls; on success it navigates to the gallery.
 * @param slot the content container provided by the router
 */
export default function render(slot) {
  const email = field({ type: 'email', name: 'email', placeholder: 'Email', required: true, autocomplete: 'email' });
  const password = field({ type: 'password', name: 'password', placeholder: 'Password', required: true, autocomplete: 'current-password' });
  const submit = submitButton('Log In');
  const form = el('form', { class: 'space-y-2' }, [email, password, submit]);
  form.addEventListener('submit', (e) => onSubmit(e, { email, password, submit, form }));
  const forgot = el('div', { class: 'text-center mt-5' }, [
    el('a', { href: '/forgot-password', 'data-link': true, class: 'text-xs text-ig-dkblue hover:underline' }, ['Forgot password?']),
  ]);
  slot.append(el('div', {}, [authCard([form, forgot]), linkRow("Don't have an account?", '/register', 'Sign up')]));
}

/** onSubmit signs in with the entered credentials, surfacing any auth error. */
async function onSubmit(event, ui) {
  event.preventDefault();
  ui.submit.disabled = true;
  try {
    await baas.auth.signInWithPassword({ email: ui.email.value.trim(), password: ui.password.value });
    window.canagrouNavigate('/');
  } catch (err) {
    showError(ui.form, err && err.message ? err.message : 'Login failed');
  } finally {
    ui.submit.disabled = false;
  }
}
