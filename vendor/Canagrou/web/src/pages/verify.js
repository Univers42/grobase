// verify.js — email confirmation landing. Reads ?token= & ?type= from the URL
// and calls baas.auth.verify. In dev GoTrue autoconfirm is ON, so this is
// effectively a no-op success path; the page still exists to handle the link.

import { baas } from '../lib/baas.js';
import { el } from '../lib/dom.js';
import { authCard } from '../components/auth-form.js';

/**
 * render shows a verifying state, attempts verification from URL params, and
 * reports the outcome. The default export the router calls.
 * @param slot the content container provided by the router
 */
export default async function render(slot) {
  const status = el('p', { class: 'text-ig-muted text-sm' }, ['Confirming your account…']);
  const home = el('a', { href: '/login', 'data-link': true, class: 'text-ig-blue font-semibold text-sm mt-4 inline-block' }, ['Continue to log in']);
  slot.append(authCard([el('div', { class: 'text-center' }, [status, home])]));
  await runVerify(status);
}

/** runVerify pulls token/type from the URL and calls auth.verify, if present. */
async function runVerify(status) {
  const params = new URLSearchParams(window.location.search);
  const token = params.get('token');
  const type = params.get('type') || 'signup';
  if (!token) {
    status.textContent = 'Your account is confirmed. You can log in.';
    return;
  }
  try {
    await baas.auth.verify({ type, token });
    status.textContent = 'Account confirmed. You are signed in.';
  } catch (err) {
    status.textContent = err && err.message ? err.message : 'Verification link is invalid or expired.';
  }
}
