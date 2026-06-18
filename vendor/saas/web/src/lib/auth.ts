// auth.ts — GoTrue auth surface (/auth/v1) mirroring @grobase/js shapes
// (signUp / signInWithPassword / recover / signOut). Auth needs only the Kong
// anon key + the user JWT; the mbk_ tenant key is NOT used here.

import type { BaasConfig } from './config';
import type { Session, SessionStore, SessionUser } from './session';
import { isRecord, asString } from './guards';

/** AuthResult is what signIn/signUp return to callers: the user + access token. */
export type AuthResult = { user: SessionUser | null; accessToken: string };

/** AuthError carries GoTrue's machine-readable error_code (e.g. user_already_exists)
 *  alongside the human message, so callers can branch on the code instead of
 *  string-matching — GoTrue is shared platform-wide, so collisions are expected. */
export class AuthError extends Error {
  readonly code: string;

  constructor(message: string, code: string) {
    super(message);
    this.name = 'AuthError';
    this.code = code;
  }
}

/** Auth is the auth client surface bound to a session store. */
export type Auth = {
  signUp: (i: { email: string; password: string; username?: string }) => Promise<AuthResult>;
  signInWithPassword: (i: { email: string; password: string }) => Promise<AuthResult>;
  recover: (i: { email: string }) => Promise<void>;
  signOut: () => Promise<void>;
  currentUser: () => SessionUser | null;
  accessToken: () => string;
  isAuthed: () => boolean;
};

/** EMAIL_TAKEN_CODES are the GoTrue error_codes meaning the email is already
 *  registered (GoTrue is shared platform-wide, so this is an expected collision). */
const EMAIL_TAKEN_CODES = new Set(['user_already_exists', 'email_exists']);

/** isEmailTaken reports whether an error is GoTrue's "email already registered". */
export function isEmailTaken(error: unknown): boolean {
  return error instanceof AuthError && EMAIL_TAKEN_CODES.has(error.code);
}

/** decodeUser extracts {id,email,username} from a JWT payload (no verification). */
function decodeUser(token: string): SessionUser | null {
  try {
    const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims: unknown = JSON.parse(atob(part));
    if (!isRecord(claims)) return null;
    const meta = isRecord(claims.user_metadata) ? claims.user_metadata : {};
    return { id: asString(claims.sub), email: asString(claims.email), username: asString(meta.username) };
  } catch {
    return null;
  }
}

/** normalizeUser builds a flat SessionUser from a GoTrue user object or the token. */
function normalizeUser(user: unknown, token: string): SessionUser | null {
  if (isRecord(user) && user.id) {
    const meta = isRecord(user.user_metadata) ? user.user_metadata : {};
    return { id: asString(user.id), email: asString(user.email), username: asString(meta.username) };
  }
  return decodeUser(token);
}

/** errorMessage pulls the most specific GoTrue error string from a response body. */
function errorMessage(body: unknown, path: string, status: number): string {
  if (isRecord(body)) {
    const m = body.error_description ?? body.msg ?? body.message ?? body.error;
    if (typeof m === 'string') return m;
  }
  return `auth ${path} failed (${status})`;
}

/** errorCode reads GoTrue's machine-readable error_code (falling back to error). */
function errorCode(body: unknown): string {
  if (isRecord(body)) {
    const c = body.error_code ?? body.error;
    if (typeof c === 'string') return c;
  }
  return 'unknown';
}

/** createAuth wires the GoTrue endpoints to the session store, persisting tokens. */
export function createAuth(config: BaasConfig, store: SessionStore): Auth {
  const base = `${config.url}/auth/v1`;

  async function post(path: string, payload: unknown, token?: string): Promise<Record<string, unknown>> {
    const headers: Record<string, string> = { apikey: config.anonKey, 'Content-Type': 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(`${base}${path}`, { method: 'POST', headers, body: JSON.stringify(payload) });
    const body: unknown = await res.json().catch(() => ({}));
    if (!res.ok) throw new AuthError(errorMessage(body, path, res.status), errorCode(body));
    return isRecord(body) ? body : {};
  }

  function persist(resp: Record<string, unknown>): AuthResult {
    const accessToken = asString(resp.access_token);
    if (accessToken) {
      const session: Session = {
        accessToken,
        refreshToken: asString(resp.refresh_token),
        user: normalizeUser(resp.user, accessToken),
      };
      store.save(session);
      return { user: session.user, accessToken };
    }
    return { user: null, accessToken: '' };
  }

  return {
    signUp: ({ email, password, username }) =>
      post('/signup', { email, password, data: { username } }).then(persist),
    signInWithPassword: ({ email, password }) =>
      post('/token?grant_type=password', { email, password }).then(persist),
    recover: ({ email }) => post('/recover', { email }).then(() => undefined),
    async signOut() {
      const s = store.load();
      if (s?.accessToken) await post('/logout', {}, s.accessToken).catch(() => undefined);
      store.clear();
    },
    currentUser: () => store.load()?.user ?? null,
    accessToken: () => store.load()?.accessToken ?? '',
    isAuthed: () => Boolean(store.load()?.accessToken),
  };
}
