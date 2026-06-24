// forgot-password.js — password-recovery request. Validates the email, calls
// baas.auth.recover({email}) (GoTrue → Mailpit in dev), and always shows a
// neutral success state so the form never reveals whether an email is registered.

import { baas } from '../lib/baas.js';
import { el, setButtonLoading } from '../lib/dom.js';
import { authCard, field, setHint, submitButton, showError, clearAlert, linkRow } from '../components/auth-form.js';
import { validateEmail } from '../lib/validate.js';

/**
 * render mounts the recovery request form. The default export the router calls.
 * @param slot the content container provided by the router
 */
export default function render(slot) {
  const email = field({ type: 'email', name: 'email', placeholder: 'Email', required: true, autocomplete: 'email', 'data-testid': 'auth-email' }, 'Email');
  const submit = submitButton('Send reset link');
  const note = el('p', { class: 'text-ig-muted text-sm text-center mb-4' }, ["Enter your email and we'll send a link to reset your password."]);
  const form = el('form', { class: 'space-y-3', novalidate: true }, [note, email.wrap, submit]);
  email.input.addEventListener('input', () => email.input.value && setHint(email, ''));
  form.addEventListener('submit', (e) => onSubmit(e, { email, submit, form }));
  slot.append(el('div', {}, [authCard([form], 'Reset your password.'), linkRow('Remembered it?', '/login', 'Back to log in', 'nav-login')]));
}

/** onSubmit validates, sends the recovery email, and shows a neutral success. */
async function onSubmit(event, ui) {
  event.preventDefault();
  clearAlert(ui.form);
  const err = validateEmail(ui.email.input.value);
  setHint(ui.email, err);
  if (err) return;
  setButtonLoading(ui.submit, true, 'Sending…');
  try {
    await baas.auth.recover({ email: ui.email.input.value.trim() });
    showSent(ui);
  } catch (err) {
    setButtonLoading(ui.submit, false);
    showError(ui.form, err && err.message ? err.message : 'Could not send the reset link');
  }
}

/** showSent replaces the form interaction with a confirming success alert. */
function showSent(ui) {
  setButtonLoading(ui.submit, false);
  ui.submit.disabled = true;
  ui.submit.textContent = 'Check your inbox';
  ui.email.input.disabled = true;
  showError(ui.form, 'If that email is registered, a reset link is on its way.', 'success');
}
