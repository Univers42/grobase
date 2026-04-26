export interface User {
  id?: string;
  email?: string;
  role?: string;
  [key: string]: unknown;
}

export interface AuthSession {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  expires_at?: number;
  token_type?: string;
  user?: User;
  [key: string]: unknown;
}

export interface ClientSession {
  accessToken: string;
  refreshToken?: string;
  expiresAt?: number;
}

export type SessionInput = string | ClientSession | AuthSession;

export function normalizeSession(session: SessionInput): ClientSession {
  if (typeof session === 'string') return { accessToken: session };

  if (isClientSession(session)) {
    return {
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresAt: session.expiresAt,
    };
  }

  return {
    accessToken: session.access_token,
    refreshToken: session.refresh_token,
    expiresAt: session.expires_at ?? computeExpiresAt(session.expires_in),
  };
}

function computeExpiresAt(expiresIn?: number): number | undefined {
  if (!expiresIn) return undefined;
  return Math.floor(Date.now() / 1000) + expiresIn;
}

function isClientSession(session: ClientSession | AuthSession): session is ClientSession {
  return typeof (session as ClientSession).accessToken === 'string';
}
