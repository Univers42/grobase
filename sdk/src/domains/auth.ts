/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { routes } from '../core/routes.js';
import type { AuthSession, User } from '../core/session.js';
import type { HttpClient } from '../core/http.js';
import type {
  AdminCreateUserInput,
  AdminGenerateLinkInput,
  AdminUpdateUserInput,
  MfaChallengeInput,
  MfaChallengeResult,
  MfaEnrollInput,
  MfaEnrollResult,
  MfaVerifyInput,
  RecoverInput,
  SignInWithOAuthInput,
  SignInWithOAuthResult,
  SignInWithPasswordInput,
  SignUpInput,
  UpdateUserInput,
  VerifyInput,
} from '../types.js';

export class AuthClient {
  readonly admin: AuthAdminClient;
  /** Multi-factor (TOTP / phone) enrollment + challenge/verify (gotrue). */
  readonly mfa: AuthMfaClient;

  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {
    this.admin = new AuthAdminClient(http, serviceRoleKey);
    this.mfa = new AuthMfaClient(http);
  }

  async signIn(input: SignInWithPasswordInput): Promise<AuthSession> {
    return this.signInWithPassword(input);
  }

  /**
   * Build the gotrue `/auth/v1/authorize` URL for a social/OIDC provider. Like
   * supabase-js, this does **not** issue a request — it returns the URL the
   * caller opens in the browser (gotrue 302s to the provider, then back to
   * `redirectTo`). The `apikey` is appended so the gateway accepts the redirect.
   */
  signInWithOAuth(input: SignInWithOAuthInput): SignInWithOAuthResult {
    const url = this.http.buildUrl(routes.auth.authorize);
    url.searchParams.set('provider', input.provider);
    url.searchParams.set('apikey', this.http.getAnonKey());
    if (input.redirectTo) url.searchParams.set('redirect_to', input.redirectTo);
    if (input.scopes) url.searchParams.set('scopes', input.scopes);
    for (const [key, value] of Object.entries(input.queryParams ?? {})) {
      url.searchParams.set(key, value);
    }
    return { provider: input.provider, url: url.toString() };
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

  async signUp(input: SignUpInput): Promise<AuthSession | User> {
    return this.http.request<AuthSession | User>(routes.auth.signup, {
      method: 'POST',
      body: input,
      auth: false,
    });
  }

  async recover(input: RecoverInput): Promise<unknown> {
    return this.http.request(routes.auth.recover, {
      method: 'POST',
      body: input,
      auth: false,
    });
  }

  async verify(input: VerifyInput): Promise<AuthSession | User> {
    const session = await this.http.request<AuthSession | User>(routes.auth.verify, {
      method: 'POST',
      body: input,
      auth: false,
    });

    if (isAuthSession(session)) this.http.setSession(session);
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

  async updateUser(input: UpdateUserInput, accessToken?: string): Promise<User> {
    return this.http.request<User>(routes.auth.user, {
      method: 'POST',
      body: input,
      bearerToken: accessToken,
    });
  }

  async user(): Promise<User> {
    return this.getUser();
  }
}

export class AuthAdminClient {
  constructor(
    private readonly http: HttpClient,
    private readonly serviceRoleKey?: string,
  ) {}

  async createUser(input: AdminCreateUserInput): Promise<User> {
    return this.request<User>(routes.auth.adminUsers, 'POST', input);
  }

  async updateUser(id: string, input: AdminUpdateUserInput): Promise<User> {
    return this.request<User>(routes.auth.adminUser(id), 'PATCH', input);
  }

  async generateLink(input: AdminGenerateLinkInput): Promise<Record<string, unknown>> {
    return this.request<Record<string, unknown>>(routes.auth.adminGenerateLink, 'POST', input);
  }

  private async request<TResult>(path: string, method: string, body: unknown): Promise<TResult> {
    if (!this.serviceRoleKey) throw new Error('Missing service role key for admin auth operation.');
    return this.http.request<TResult>(path, {
      method,
      body,
      apiKey: this.serviceRoleKey,
      bearerToken: this.serviceRoleKey,
    });
  }
}

/**
 * MFA helpers against gotrue's `/auth/v1/factors` surface. Enroll returns the
 * TOTP secret/QR (or registers a phone factor); challenge opens a verification
 * window; verify confirms the code and (on success) upgrades the session's AAL.
 * All three require an authenticated session (the user enrolling the factor).
 */
export class AuthMfaClient {
  constructor(private readonly http: HttpClient) {}

  async enroll(input: MfaEnrollInput = {}): Promise<MfaEnrollResult> {
    return this.http.request<MfaEnrollResult>(routes.auth.factors, {
      method: 'POST',
      body: {
        factor_type: input.factorType ?? 'totp',
        friendly_name: input.friendlyName,
        issuer: input.issuer,
        phone: input.phone,
      },
    });
  }

  async challenge(input: MfaChallengeInput): Promise<MfaChallengeResult> {
    return this.http.request<MfaChallengeResult>(routes.auth.factorChallenge(input.factorId), {
      method: 'POST',
      body: {},
    });
  }

  async verify(input: MfaVerifyInput): Promise<AuthSession> {
    const session = await this.http.request<AuthSession>(routes.auth.factorVerify(input.factorId), {
      method: 'POST',
      body: { challenge_id: input.challengeId, code: input.code },
    });
    if (isAuthSession(session)) this.http.setSession(session);
    return session;
  }

  async unenroll(factorId: string): Promise<unknown> {
    return this.http.request(routes.auth.factor(factorId), { method: 'DELETE' });
  }
}

function isAuthSession(value: AuthSession | User): value is AuthSession {
  return typeof (value as AuthSession).access_token === 'string';
}
