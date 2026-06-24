import type { BaasConfig } from './config.ts';
import { baseHeaders, requestJson } from './http.ts';
import { saveSession, type Session } from './session.ts';

export type RegisterInput = {
  email: string;
  username: string;
  firstName: string;
  lastName: string;
  password: string;
};

type GoTrueToken = {
  access_token: string;
  refresh_token: string;
  user: { id: string };
};

/** toSession maps a GoTrue token payload to the persisted Session shape. */
function toSession(t: GoTrueToken): Session {
  return { accessToken: t.access_token, refreshToken: t.refresh_token, userId: t.user.id };
}

/** signUp registers a new user with username/name carried in user_metadata. */
export async function signUp(cfg: BaasConfig, input: RegisterInput): Promise<Session> {
  const t = await requestJson<GoTrueToken>('/auth/v1/signup', {
    method: 'POST',
    headers: baseHeaders(cfg, false),
    body: JSON.stringify({
      email: input.email,
      password: input.password,
      data: { username: input.username, first_name: input.firstName, last_name: input.lastName },
    }),
  });
  const session = toSession(t);
  saveSession(session);
  return session;
}

/** signIn exchanges email+password for a session via the password grant. */
export async function signIn(cfg: BaasConfig, email: string, password: string): Promise<Session> {
  const t = await requestJson<GoTrueToken>('/auth/v1/token?grant_type=password', {
    method: 'POST',
    headers: baseHeaders(cfg, false),
    body: JSON.stringify({ email, password }),
  });
  const session = toSession(t);
  saveSession(session);
  return session;
}

/** recover triggers a password-reset email for the given address. */
export async function recover(cfg: BaasConfig, email: string): Promise<void> {
  await requestJson<unknown>('/auth/v1/recover', {
    method: 'POST',
    headers: baseHeaders(cfg, false),
    body: JSON.stringify({ email }),
  });
}

/** signOut revokes the server session (best-effort) and clears local state. */
export async function signOut(cfg: BaasConfig): Promise<void> {
  try {
    await requestJson<unknown>('/auth/v1/logout', { method: 'POST', headers: baseHeaders(cfg) });
  } catch {
    // local clear is the source of truth; ignore a server-side logout failure
  }
  saveSession(null);
}

/** updateEmail changes the caller's own GoTrue email (owner-only by token). */
export async function updateEmail(cfg: BaasConfig, email: string): Promise<void> {
  await requestJson<unknown>('/auth/v1/user', {
    method: 'PUT',
    headers: baseHeaders(cfg),
    body: JSON.stringify({ email }),
  });
}

/** oauthUrl returns the GoTrue authorize URL for an external provider. */
export function oauthUrl(provider: 'fortytwo' | 'google'): string {
  const redirect = encodeURIComponent(`${window.location.origin}/library`);
  return `/auth/v1/authorize?provider=${provider}&redirect_to=${redirect}`;
}
