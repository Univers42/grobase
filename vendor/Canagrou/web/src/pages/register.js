// register.js — sign-up page. Validates email/username/password/confirm inline,
// calls baas.auth.signUp, inserts the matching profiles row (id = GoTrue sub,
// notify_comments=true), shows loading then success on the button, and routes
// home. Placeholders and the "Sign up" label are contract for the e2e suite.

import { baas } from '../lib/baas.js';
import { ensureProfile } from '../lib/profiles.js';
import { el, setButtonLoading, clear } from '../lib/dom.js';
import { authCard, field, setHint, submitButton, showError, clearAlert, linkRow } from '../components/auth-form.js';
import { validateEmail, validatePassword, validateUsername, validateMatch } from '../lib/validate.js';

/**
 * render mounts the registration form. The default export the router calls; on
 * success it creates the profile and navigates to the gallery.
 * @param slot the content container provided by the router
 */
export default function render(slot) {
  const ui = buildFields();
  ui.submit = submitButton('Sign up');
  ui.form = el('form', { class: 'space-y-3', novalidate: true }, [ui.email.wrap, ui.username.wrap, ui.password.wrap, ui.confirm.wrap, ui.submit]);
  wireValidation(ui);
  ui.form.addEventListener('submit', (e) => onSubmit(e, ui));
  slot.append(el('div', {}, [
    authCard([ui.form], 'Sign up to capture, create and share moments.'),
    linkRow('Have an account?', '/login', 'Log in', 'nav-login'),
  ]));
}

/** buildFields constructs the four labelled inputs for the sign-up form. */
function buildFields() {
  return {
    email: field({ type: 'email', name: 'email', placeholder: 'Email', required: true, autocomplete: 'email', 'data-testid': 'auth-email' }, 'Email'),
    username: field({ type: 'text', name: 'username', placeholder: 'Username', required: true, autocomplete: 'username', 'data-testid': 'auth-username' }, 'Username'),
    password: field({ type: 'password', name: 'password', placeholder: 'Password', required: true, autocomplete: 'new-password', 'data-testid': 'auth-password' }, 'Password'),
    confirm: field({ type: 'password', name: 'confirm', placeholder: 'Confirm Password', required: true, autocomplete: 'new-password', 'data-testid': 'auth-confirm' }, 'Confirm password'),
  };
}

/** wireValidation gives each field live, debounced inline feedback as it's edited. */
function wireValidation(ui) {
  ui.email.input.addEventListener('blur', () => setHint(ui.email, validateEmail(ui.email.input.value)));
  ui.username.input.addEventListener('blur', () => setHint(ui.username, validateUsername(ui.username.input.value)));
  ui.password.input.addEventListener('input', () => livePassword(ui));
  ui.confirm.input.addEventListener('input', () => liveConfirm(ui));
}

/** livePassword rates the password as the user types it. */
function livePassword(ui) {
  const err = validatePassword(ui.password.input.value);
  setHint(ui.password, err || 'Strong enough', err ? 'error' : 'ok');
  if (ui.confirm.input.value) liveConfirm(ui);
}

/** liveConfirm checks the confirm field against the password as it's typed. */
function liveConfirm(ui) {
  const err = validateMatch(ui.password.input.value, ui.confirm.input.value);
  setHint(ui.confirm, err || 'Passwords match', err ? 'error' : 'ok');
}

/** onSubmit validates, signs up, creates the profile, then routes home. */
async function onSubmit(event, ui) {
  event.preventDefault();
  clearAlert(ui.form);
  if (!checkValid(ui)) return;
  setButtonLoading(ui.submit, true, 'Creating account…');
  try {
    await baas.auth.signUp({ email: ui.email.input.value.trim(), password: ui.password.input.value, username: ui.username.input.value.trim() });
    await ensureProfile(ui.username.input.value.trim());
    flashSuccess(ui.submit);
    setTimeout(() => window.canagrouNavigate('/'), 450);
  } catch (err) {
    setButtonLoading(ui.submit, false);
    const msg = (err && err.message) || '';
    if (/already (registered|exists|been registered)/i.test(msg)) {
      showError(ui.form, 'That email is already registered — taking you to log in…');
      setTimeout(() => window.canagrouNavigate('/login'), 1400);
    } else {
      showError(ui.form, msg || 'Registration failed — please try again');
    }
  }
}

/** checkValid runs every validator, surfaces hints, and returns overall validity. */
function checkValid(ui) {
  const errs = {
    email: validateEmail(ui.email.input.value),
    username: validateUsername(ui.username.input.value),
    password: validatePassword(ui.password.input.value),
    confirm: validateMatch(ui.password.input.value, ui.confirm.input.value),
  };
  for (const key of Object.keys(errs)) setHint(ui[key], errs[key]);
  return Object.values(errs).every((e) => !e);
}

/** flashSuccess turns the submit button green with a confirming label. */
function flashSuccess(btn) {
  btn.disabled = true;
  clear(btn);
  btn.style.background = 'linear-gradient(120deg,#059669,#047857)';
  btn.append(el('span', { text: 'Account created!' }));
}
