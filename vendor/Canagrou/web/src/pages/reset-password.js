// reset-password.js — recovery-link landing. Reads ?token= from the URL and
// calls baas.auth.verify({type:'recovery',token}) to confirm the recovery
// session. (GoTrue autoconfirm in dev makes this a confirmation path; a full
// password update would extend the lib, which is out of scope here.)

import { baas } from '../lib/baas.js';
import { el } from '../lib/dom.js';
import { authCard } from '../components/auth-form.js';

/**
 * render confirms a recovery token from the URL and reports the outcome with a
 * link onward. The default export the router calls.
 * @param slot the content container provided by the router
 */
export default async function render(slot) {
  const status = el('p', { class: 'text-ig-muted text-sm' }, ['Validating your reset link…']);
  const onward = el('a', { href: '/login', 'data-link': true, class: 'text-ig-blue font-semibold text-sm mt-4 inline-block' }, ['Continue to log in']);
  slot.append(authCard([el('div', { class: 'text-center' }, [status, onward])]));
  await runReset(status);
}

/** runReset verifies the recovery token (if any) from the query string. */
async function runReset(status) {
  const token = new URLSearchParams(window.location.search).get('token');
  if (!token) {
    status.textContent = 'No reset token found. Request a new link from "Forgot password".';
    return;
  }
  try {
    await baas.auth.verify({ type: 'recovery', token });
    status.textContent = 'Reset link confirmed — you are signed in. Update your password in Settings.';
  } catch (err) {
    status.textContent = err && err.message ? err.message : 'Reset link is invalid or expired.';
  }
}
