// login.js — sign-in page. Validates email/password inline, signs in with
// baas.auth.signInWithPassword (the lib authenticates by email), shows a loading
// then success state on the button, and routes home on success.

import { baas } from '../lib/baas.js';
import { ensureProfile } from '../lib/profiles.js';
import { el, setButtonLoading, clear } from '../lib/dom.js';
import { authCard, field, setHint, submitButton, showError, clearAlert, linkRow } from '../components/auth-form.js';
import { validateEmail, validatePassword } from '../lib/validate.js';

/**
 * render mounts the login form. The default export the router calls; on success
 * it flashes the button then navigates to the gallery.
 * @param slot the content container provided by the router
 */
export default function render(slot) {
  const email = field({ type: 'email', name: 'email', placeholder: 'Email', required: true, autocomplete: 'email', 'data-testid': 'auth-email' }, 'Email');
  const password = field({ type: 'password', name: 'password', placeholder: 'Password', required: true, autocomplete: 'current-password', 'data-testid': 'auth-password' }, 'Password');
  const submit = submitButton('Log in');
  const form = el('form', { class: 'space-y-3', novalidate: true }, [email.wrap, password.wrap, submit]);
  wireValidation(email, password);
  form.addEventListener('submit', (e) => onSubmit(e, { email, password, submit, form }));
  const forgot = el('div', { class: 'text-center mt-4' }, [
    el('a', { href: '/forgot-password', 'data-link': true, class: 'text-xs text-purple-600 hover:underline' }, ['Forgot password?']),
  ]);
  slot.append(el('div', {}, [authCard([form, forgot], 'Welcome back — log in to share your moments.'), linkRow("Don't have an account?", '/register', 'Sign up', 'nav-register')]));
}

/** wireValidation clears a field's error hint as the user corrects it. */
function wireValidation(email, password) {
  email.input.addEventListener('blur', () => setHint(email, validateEmail(email.input.value)));
  email.input.addEventListener('input', () => email.input.value && setHint(email, ''));
  password.input.addEventListener('input', () => password.input.value && setHint(password, ''));
}

/** onSubmit validates, signs in with feedback, and routes home on success. */
async function onSubmit(event, ui) {
  event.preventDefault();
  clearAlert(ui.form);
  if (!checkValid(ui)) return;
  setButtonLoading(ui.submit, true, 'Signing in…');
  try {
    await baas.auth.signInWithPassword({ email: ui.email.input.value.trim(), password: ui.password.input.value });
    await ensureProfile().catch((e) => console.warn('[login] ensureProfile', e && e.message));
    flashSuccess(ui.submit);
    setTimeout(() => window.canagrouNavigate('/'), 450);
  } catch (err) {
    setButtonLoading(ui.submit, false);
    showError(ui.form, err && err.message ? err.message : 'Login failed — check your email and password');
  }
}

/** checkValid runs field validators and surfaces hints, returning overall validity. */
function checkValid(ui) {
  const e = validateEmail(ui.email.input.value);
  const p = validatePassword(ui.password.input.value);
  setHint(ui.email, e);
  setHint(ui.password, p);
  return !e && !p;
}

/** flashSuccess turns the submit button green with a confirming label. */
function flashSuccess(btn) {
  btn.disabled = true;
  clear(btn);
  btn.classList.add('!bg-emerald-600');
  btn.style.background = 'linear-gradient(120deg,#059669,#047857)';
  btn.append(el('span', { text: 'Welcome back!' }));
}
