import { routes } from '../core/routes.js';
import type { AuthSession, User } from '../core/session.js';
import type { HttpClient } from '../core/http.js';
import type { SignInWithPasswordInput } from '../types.js';

export class AuthClient {
  constructor(private readonly http: HttpClient) {}

  async signIn(input: SignInWithPasswordInput): Promise<AuthSession> {
    return this.signInWithPassword(input);
  }

  async signInWithPassword(input: SignInWithPasswordInput): Promise<AuthSession> {
    const session = await this.http.request<AuthSession>(routes.auth.token('password'), {
      method: 'POST',
      body: input,
      auth: false,
    });

    this.http.setSession(session);
    return session;
  }

  async refreshSession(refreshToken?: string): Promise<AuthSession> {
    const token = refreshToken ?? this.http.getSession()?.refreshToken;
    if (!token) throw new Error('No refresh token available');

    const session = await this.http.request<AuthSession>(routes.auth.token('refresh_token'), {
      method: 'POST',
      body: { refresh_token: token },
      auth: false,
    });

    this.http.setSession(session);
    return session;
  }

  async signOut(): Promise<void> {
    await this.http.request<void>(routes.auth.logout, { method: 'POST' });
    this.http.clearSession();
  }

  async getUser(): Promise<User> {
    return this.http.request<User>(routes.auth.user);
  }

  async user(): Promise<User> {
    return this.getUser();
  }
}
