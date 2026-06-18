// forgot-password.js — password-recovery request. Calls baas.auth.recover({email})
// which sends the GoTrue recovery email (Mailpit in dev). Always shows a neutral
// confirmation so the form never reveals whether an email is registered.

import { baas } from '../lib/baas.js';
import { el } from '../lib/dom.js';
import { authCard, field, submitButton, showError, linkRow } from '../components/auth-form.js';

/**
 * render mounts the recovery request form. The default export the router calls.
 * @param slot the content container provided by the router
 */
export default function render(slot) {
  const email = field({ type: 'email', name: 'email', placeholder: 'Email', required: true, autocomplete: 'email' });
  const submit = submitButton('Send reset link');
  const note = el('p', { class: 'text-ig-muted text-xs text-center mb-3' }, [
    "Enter your email and we'll send a link to reset your password.",
  ]);
  const form = el('form', { class: 'space-y-2' }, [note, email, submit]);
  form.addEventListener('submit', (e) => onSubmit(e, { email, submit, form }));
  slot.append(el('div', {}, [authCard([form]), linkRow('Remembered it?', '/login', 'Back to log in')]));
}

/** onSubmit sends the recovery email and shows a neutral confirmation. */
async function onSubmit(event, ui) {
  event.preventDefault();
  ui.submit.disabled = true;
  try {
    await baas.auth.recover({ email: ui.email.value.trim() });
    ui.form.querySelector('.auth-error')?.remove();
    ui.submit.textContent = 'Check your inbox';
  } catch (err) {
    showError(ui.form, err && err.message ? err.message : 'Could not send reset link');
    ui.submit.disabled = false;
  }
}
