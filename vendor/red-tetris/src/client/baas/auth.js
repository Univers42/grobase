// GoTrue auth (signup / signin / signout) over /auth/v1. The returned session's
// access_token is reused as the realtime WS token.
import { baseHeaders, requestJson } from './http.js';
import { saveSession } from './session.js';

/** toSession maps a GoTrue token payload to the persisted Session shape. */
function toSession(t) {
  return { accessToken: t.access_token, refreshToken: t.refresh_token, userId: t.user.id };
}

/** signUp registers a new user (username/name carried in user_metadata). */
export async function signUp({ email, password, username, firstName, lastName }) {
  const t = await requestJson('/auth/v1/signup', {
    method: 'POST',
    headers: baseHeaders(false),
    body: JSON.stringify({
      email,
      password,
      data: { username, first_name: firstName, last_name: lastName },
    }),
  });
  if (!t || !t.access_token) throw { status: 200, message: 'check your email to confirm, then sign in' };
  const session = toSession(t);
  saveSession(session);
  return session;
}

/** signIn exchanges email+password for a session (password grant). */
export async function signIn(email, password) {
  const t = await requestJson('/auth/v1/token?grant_type=password', {
    method: 'POST',
    headers: baseHeaders(false),
    body: JSON.stringify({ email, password }),
  });
  const session = toSession(t);
  saveSession(session);
  return session;
}

/** signOut clears the local session (best-effort server logout). */
export async function signOut() {
  try {
    await requestJson('/auth/v1/logout', { method: 'POST', headers: baseHeaders() });
  } catch {
    // local clear is the source of truth
  }
  saveSession(null);
}

/** currentUser fetches the signed-in user's GoTrue record (metadata). */
export async function currentUser() {
  return requestJson('/auth/v1/user', { method: 'GET', headers: baseHeaders() });
}

/** oauthUrl returns the GoTrue authorize URL for an external provider (42/google). */
export function oauthUrl(provider) {
  const redirect = encodeURIComponent(`${window.location.origin}/`);
  return `/auth/v1/authorize?provider=${provider}&redirect_to=${redirect}`;
}
