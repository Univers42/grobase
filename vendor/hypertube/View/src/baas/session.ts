const STORAGE_KEY = 'hypertube.session';

export type Session = {
  accessToken: string;
  refreshToken: string;
  userId: string;
};

/** loadSession reads the persisted session from localStorage, or null. */
export function loadSession(): Session | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Session;
    return parsed.accessToken ? parsed : null;
  } catch {
    return null;
  }
}

/** saveSession persists the session (or clears it when null). */
export function saveSession(session: Session | null): void {
  if (!session) {
    localStorage.removeItem(STORAGE_KEY);
    return;
  }
  localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
}

/** jwtDisplayName extracts a display name from a GoTrue JWT: the metadata
 *  username, else the email local-part, else "user". Never throws. */
export function jwtDisplayName(token: string): string {
  try {
    const seg = token.split('.')[1] ?? '';
    const json = JSON.parse(atob(seg.replace(/-/g, '+').replace(/_/g, '/'))) as {
      email?: string;
      user_metadata?: { username?: string };
    };
    const username = json.user_metadata?.username;
    return (username && String(username)) || (json.email ?? '').split('@')[0] || 'user';
  } catch {
    return 'user';
  }
}
