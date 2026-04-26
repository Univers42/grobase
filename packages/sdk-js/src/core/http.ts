import { MiniBaasError, MiniBaasTimeoutError } from './errors.js';
import { routes } from './routes.js';
import { normalizeSession, type ClientSession, type SessionInput } from './session.js';
import type { SessionStorageAdapter } from './storage.js';
import type { RetryOptions } from '../index.js';

interface HttpClientOptions {
  baseUrl: string;
  anonKey: string;
  fetch?: typeof fetch;
  sessionStorage: SessionStorageAdapter;
  session?: ClientSession;
  timeoutMs?: number;
  retry?: number | RetryOptions;
}

interface RequestOptions {
  method?: string;
  body?: unknown;
  headers?: HeadersInit;
  auth?: boolean;
}

export class HttpClient {
  private readonly baseUrl: string;
  private readonly anonKey: string;
  private readonly fetchImpl: typeof fetch;
  private readonly sessionStorage: SessionStorageAdapter;
  private readonly timeoutMs: number;
  private readonly retry: Required<RetryOptions>;
  private session?: ClientSession;

  constructor(options: HttpClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '');
    this.anonKey = options.anonKey;
    this.fetchImpl = options.fetch ?? fetch;
    this.sessionStorage = options.sessionStorage;
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.retry = normalizeRetry(options.retry);

    if (options.session) this.setSession(options.session);
  }

  setSession(session: SessionInput): void {
    this.session = normalizeSession(session);
    this.sessionStorage.save(this.session);
  }

  getSession(): ClientSession | undefined {
    return this.session;
  }

  clearSession(): void {
    this.session = undefined;
    this.sessionStorage.clear();
  }

  createRealtimeUrl(channel: string): URL {
    const url = new URL(routes.realtime.channel(channel), this.baseUrl);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    return url;
  }

  async request<T = unknown>(path: string, init: RequestOptions = {}): Promise<T> {
    const attempts = Math.max(1, this.retry.attempts);
    let lastError: unknown;

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await this.fetchOnce<T>(path, init);
      } catch (error) {
        lastError = error;
        if (!this.shouldRetry(error, attempt, attempts)) throw error;
        await delay(this.retry.delayMs * attempt);
      }
    }

    throw lastError;
  }

  private async fetchOnce<T>(path: string, init: RequestOptions): Promise<T> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: init.method ?? 'GET',
        headers: this.buildHeaders(init),
        body: init.body === undefined ? undefined : JSON.stringify(init.body),
        signal: controller.signal,
      });

      const body = await parseBody(response);

      if (!response.ok) {
        throw new MiniBaasError(
          extractErrorMessage(body) ?? response.statusText,
          response.status,
          body,
        );
      }

      return body as T;
    } catch (error) {
      if (isAbortError(error)) throw new MiniBaasTimeoutError(this.timeoutMs);
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }

  private buildHeaders(init: RequestOptions): Headers {
    const headers = new Headers(init.headers);
    headers.set('apikey', this.anonKey);

    if (init.auth !== false) {
      headers.set('Authorization', `Bearer ${this.session?.accessToken ?? this.anonKey}`);
    }

    if (init.body !== undefined) headers.set('Content-Type', 'application/json');

    return headers;
  }

  private shouldRetry(error: unknown, attempt: number, attempts: number): boolean {
    if (attempt >= attempts) return false;
    if (error instanceof MiniBaasTimeoutError) return true;
    if (error instanceof MiniBaasError) return this.retry.retryOn.includes(error.status);
    return true;
  }
}

function normalizeRetry(retry?: number | RetryOptions): Required<RetryOptions> {
  if (typeof retry === 'number') {
    return { attempts: retry, delayMs: 250, retryOn: [408, 425, 429, 500, 502, 503, 504] };
  }

  return {
    attempts: retry?.attempts ?? 2,
    delayMs: retry?.delayMs ?? 250,
    retryOn: retry?.retryOn ?? [408, 425, 429, 500, 502, 503, 504],
  };
}

async function parseBody(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function extractErrorMessage(body: unknown): string | undefined {
  if (!body || typeof body !== 'object') return undefined;
  const value = (body as { message?: unknown; error?: unknown }).message ??
    (body as { error?: unknown }).error;
  return typeof value === 'string' ? value : undefined;
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError';
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
