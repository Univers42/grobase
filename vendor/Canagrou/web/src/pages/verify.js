// verify.js — email confirmation landing. Reads ?token= & ?type= from the URL
// and calls baas.auth.verify. In dev GoTrue autoconfirm is ON, so this is
// effectively a success path; the page shows a spinner then a clear outcome.

import { baas } from '../lib/baas.js';
import { authCard } from '../components/auth-form.js';
import { statusBlock, setStatus } from '../components/status-block.js';

/**
 * render shows a verifying state, attempts verification from URL params, and
 * reports the outcome. The default export the router calls.
 * @param slot the content container provided by the router
 */
export default async function render(slot) {
  const block = statusBlock('Confirming your account…', '/login', 'Continue to log in');
  slot.append(authCard([block.element]));
  await runVerify(block);
}

/** runVerify pulls token/type from the URL and calls auth.verify, if present. */
async function runVerify(block) {
  const params = new URLSearchParams(window.location.search);
  const token = params.get('token');
  const type = params.get('type') || 'signup';
  if (!token) {
    setStatus(block, 'Your account is confirmed. You can log in.', 'success');
    return;
  }
  try {
    await baas.auth.verify({ type, token });
    setStatus(block, 'Account confirmed — you are signed in.', 'success');
  } catch (err) {
    setStatus(block, err && err.message ? err.message : 'Verification link is invalid or expired.', 'error');
  }
}
