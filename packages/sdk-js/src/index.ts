import { AnalyticsClient } from './domains/analytics.js';
import { AuthClient } from './domains/auth.js';
import { QueryClient, ResourceQueryBuilder } from './domains/query.js';
import { StorageClient } from './domains/storage.js';
import { HttpClient } from './core/http.js';
import {
  createBrowserStorageAdapter,
  createMemoryStorageAdapter,
  type SessionStorageAdapter,
} from './core/storage.js';
import type { ClientSession, SessionInput } from './core/session.js';

export type {
  AuthSession,
  ClientSession,
  SessionInput,
  User,
} from './core/session.js';
export type { SessionStorageAdapter } from './core/storage.js';
export { MiniBaasError, MiniBaasTimeoutError } from './core/errors.js';
export type {
  AnalyticsTrackInput,
  PresignInput,
  QueryRunInput,
  QueryRunResponse,
  SignInWithPasswordInput,
} from './types.js';

export interface RetryOptions {
  attempts?: number;
  delayMs?: number;
  retryOn?: number[];
}

export interface MiniBaasClientOptions {
  url: string;
  anonKey: string;
  fetch?: typeof fetch;
  accessToken?: string;
  refreshToken?: string;
  defaultDatabaseId?: string;
  persistSession?: boolean;
  storage?: SessionStorageAdapter;
  storageKey?: string;
  timeoutMs?: number;
  retry?: number | RetryOptions;
}

export class MiniBaasClient {
  readonly auth: AuthClient;
  readonly query: QueryClient;
  readonly storage: StorageClient;
  readonly analytics: AnalyticsClient;

  private readonly http: HttpClient;
  private readonly anonKey: string;

  constructor(options: MiniBaasClientOptions) {
    const sessionStorage = resolveSessionStorage(options);
    const initialSession = sessionStorage.load() ??
      (options.accessToken
        ? { accessToken: options.accessToken, refreshToken: options.refreshToken }
        : undefined);

    this.anonKey = options.anonKey;
    this.http = new HttpClient({
      baseUrl: options.url,
      anonKey: options.anonKey,
      fetch: options.fetch,
      sessionStorage,
      session: initialSession,
      timeoutMs: options.timeoutMs,
      retry: options.retry,
    });

    this.auth = new AuthClient(this.http);
    this.query = new QueryClient(this.http, options.defaultDatabaseId ?? 'default');
    this.storage = new StorageClient(this.http);
    this.analytics = new AnalyticsClient(this.http);
  }

  from<Row = Record<string, unknown>>(resource: string, databaseId?: string): ResourceQueryBuilder<Row> {
    return this.query.from<Row>(resource, databaseId);
  }

  setSession(session: SessionInput): void {
    this.http.setSession(session);
  }

  getSession(): ClientSession | undefined {
    return this.http.getSession();
  }

  clearSession(): void {
    this.http.clearSession();
  }

  realtimeUrl(channel = 'default'): string {
    const url = this.http.createRealtimeUrl(channel);
    url.searchParams.set('apikey', this.anonKey);

    const session = this.http.getSession();
    if (session?.accessToken) url.searchParams.set('access_token', session.accessToken);

    return url.toString();
  }
}

export function createClient(options: MiniBaasClientOptions): MiniBaasClient {
  return new MiniBaasClient(options);
}

function resolveSessionStorage(options: MiniBaasClientOptions): SessionStorageAdapter {
  if (options.storage) return options.storage;
  if (options.persistSession === false) return createMemoryStorageAdapter();

  return createBrowserStorageAdapter(options.storageKey) ?? createMemoryStorageAdapter();
}
