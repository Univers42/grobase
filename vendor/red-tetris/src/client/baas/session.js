// Persisted GoTrue session (localStorage). The access_token doubles as the
// realtime WS token, so every player gets a distinct identity in a room.

const STORAGE_KEY = 'red-tetris.session';

/** loadSession reads the persisted session from localStorage, or null. */
export function loadSession() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return parsed && parsed.accessToken ? parsed : null;
  } catch {
    return null;
  }
}

/** saveSession persists the session (or clears it when null). */
export function saveSession(session) {
  if (!session) {
    localStorage.removeItem(STORAGE_KEY);
    return;
  }
  localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
}

/** accessToken returns the current access token, or '' when signed out. */
export function accessToken() {
  const s = loadSession();
  return s ? s.accessToken : '';
}

/** currentUserId returns the signed-in user's id (GoTrue sub), or ''. */
export function currentUserId() {
  const s = loadSession();
  return s ? s.userId : '';
}

/** jwtClaims decodes a JWT payload without verifying (display only). */
export function jwtClaims(token) {
  try {
    const seg = (token || '').split('.')[1] || '';
    return JSON.parse(atob(seg.replace(/-/g, '+').replace(/_/g, '/')));
  } catch {
    return {};
  }
}
