// reset-password.js — recovery-link landing. Reads ?token= from the URL and
// calls baas.auth.verify({type:'recovery',token}) to confirm the recovery
// session, showing a spinner then the outcome. (A full password update would
// extend the lib, which is out of scope here.)

import { baas } from '../lib/baas.js';
import { authCard } from '../components/auth-form.js';
import { statusBlock, setStatus } from '../components/status-block.js';

/**
 * render confirms a recovery token from the URL and reports the outcome with an
 * onward link. The default export the router calls.
 * @param slot the content container provided by the router
 */
export default async function render(slot) {
  const block = statusBlock('Validating your reset link…', '/login', 'Continue to log in');
  slot.append(authCard([block.element]));
  await runReset(block);
}

/** runReset verifies the recovery token (if any) from the query string. */
async function runReset(block) {
  const token = new URLSearchParams(window.location.search).get('token');
  if (!token) {
    setStatus(block, 'No reset token found. Request a new link from "Forgot password".', 'error');
    return;
  }
  try {
    await baas.auth.verify({ type: 'recovery', token });
    setStatus(block, 'Reset link confirmed — you are signed in. Update your password in Settings.', 'success');
  } catch (err) {
    setStatus(block, err && err.message ? err.message : 'Reset link is invalid or expired.', 'error');
  }
}
