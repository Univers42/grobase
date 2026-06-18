// session.ts — localStorage-backed session store holding the GoTrue JWT pair and
// the resolved user, memoized in memory so a reload stays signed in.

import { isRecord, asString } from './guards';

/** SessionUser is the flattened identity persisted alongside the tokens. */
export type SessionUser = { id: string; email: string; username: string };

/** Session is the stored auth snapshot. */
export type Session = { accessToken: string; refreshToken: string; user: SessionUser | null };

/** SessionStore is the load/save/clear surface over localStorage. */
export type SessionStore = {
  load: () => Session | null;
  save: (session: Session) => void;
  clear: () => void;
};

const KEY = 'nimbus.session';

/** parseUser narrows an unknown stored user to a SessionUser, or null. */
function parseUser(value: unknown): SessionUser | null {
  if (!isRecord(value)) return null;
  return { id: asString(value.id), email: asString(value.email), username: asString(value.username) };
}

/** parseSession narrows a parsed localStorage payload to a Session, or null. */
function parseSession(value: unknown): Session | null {
  if (!isRecord(value)) return null;
  const accessToken = asString(value.accessToken);
  if (!accessToken) return null;
  return { accessToken, refreshToken: asString(value.refreshToken), user: parseUser(value.user) };
}

/** createSessionStore returns a memoized load/save/clear store over localStorage. */
export function createSessionStore(): SessionStore {
  let mem: Session | null | undefined;
  return {
    load() {
      if (mem !== undefined) return mem;
      try {
        mem = parseSession(JSON.parse(localStorage.getItem(KEY) ?? 'null'));
      } catch {
        mem = null;
      }
      return mem;
    },
    save(session) {
      mem = session;
      localStorage.setItem(KEY, JSON.stringify(session));
    },
    clear() {
      mem = null;
      localStorage.removeItem(KEY);
    },
  };
}
