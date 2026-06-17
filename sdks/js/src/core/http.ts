/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   http.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  MiniBaasError,
  MiniBaasNetworkError,
  MiniBaasRateLimitError,
  MiniBaasTimeoutError,
  RETRYABLE_STATUSES,
  httpError,
} from './errors.js';
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

export interface RequestOptions {
  method?: string;
  body?: unknown;
  headers?: HeadersInit;
  auth?: boolean;
  apiKey?: string;
  bearerToken?: string;
  /** Per-call timeout override (ms). Falls back to the client default. */
  timeoutMs?: number;
  /** External abort signal — composed with the per-call timeout. */
  signal?: AbortSignal;
  /**
   * Force the retry decision for this call:
   *  - `true`  — treat as idempotent (retry on retryable status / network).
   *  - `false` — never retry (e.g. a non-idempotent POST create).
   * When unset, idempotency is inferred from the HTTP method (GET/HEAD/PUT/
   * DELETE are idempotent; POST/PATCH are not).
   */
  idempotent?: boolean;
}

/** Required, fully-resolved retry policy. */
export interface ResolvedRetry {
  attempts: number;
  delayMs: number;
  maxDelayMs: number;
  retryOn: number[];
}

const IDEMPOTENT_METHODS = new Set(['GET', 'HEAD', 'OPTIONS', 'PUT', 'DELETE']);

export class HttpClient {
  private readonly baseUrl: string;
  private readonly anonKey: string;
  private readonly fetchImpl: typeof fetch;
  private readonly sessionStorage: SessionStorageAdapter;
  private readonly timeoutMs: number;
  private readonly retry: ResolvedRetry;
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
    const url = this.createRealtimeWsUrl();
    url.searchParams.set('channel', channel);
    return url;
  }

  /**
   * M10.b — Build the WS URL the *dlesieur/realtime-agnostic* server exposes.
   *
   * The Rust engine mounts `/ws` (no channel suffix); the channel travels in
   * the subscribe message body. Kong routes `/realtime/v1/ws` → `realtime:4000/ws`
   * with `strip_path: true`, so the SDK must hit exactly `/realtime/v1/ws`
   * — no trailing channel. `apikey` + `access_token` go on the query string
   * because the browser `WebSocket` constructor cannot set request headers.
   */
  createRealtimeWsUrl(): URL {
    const url = new URL('/realtime/v1/ws', this.baseUrl);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('apikey', this.anonKey);
    if (this.session?.accessToken) url.searchParams.set('access_token', this.session.accessToken);
    return url;
  }

  getRealtimeAuthToken(): string {
    return this.session?.accessToken ?? this.anonKey;
  }

  /** The gateway anon (publishable) key — needed on OAuth redirect URLs. */
  getAnonKey(): string {
    return this.anonKey;
  }

  /**
   * Build an absolute gateway URL for a `path` (used by browser-redirect flows
   * like OAuth where the SDK hands back a URL rather than issuing a request).
   */
  buildUrl(path: string): URL {
    return new URL(`${this.baseUrl}${path}`);
  }

  async request<T = unknown>(path: string, init: RequestOptions = {}): Promise<T> {
    const attempts = Math.max(1, this.retry.attempts);
    const idempotent = this.isIdempotent(init);
    let lastError: unknown;

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await this.fetchOnce<T>(path, init);
      } catch (error) {
        lastError = error;
        const wait = this.retryDelay(error, idempotent, attempt, attempts);
        if (wait === undefined) throw error;
        await delay(wait);
      }
    }

    throw lastError;
  }

  /**
   * Raw fetch for binary payloads (storage upload/download). Bypasses the JSON
   * (de)serialization of `request()`: the body is sent verbatim and the raw
   * `Response` is returned for the caller to read as blob/arrayBuffer/text.
   * Auth headers (apikey + bearer) are still applied. Supports a per-call
   * timeout + external signal but does NOT auto-retry (the body may not be
   * re-readable).
   */
  async rawFetch(
    path: string,
    init: {
      method?: string;
      body?: BodyInit | null;
      headers?: HeadersInit;
      timeoutMs?: number;
      signal?: AbortSignal;
    } = {},
  ): Promise<Response> {
    const headers = new Headers(init.headers);
    headers.set('apikey', this.anonKey);
    headers.set('Authorization', `Bearer ${this.session?.accessToken ?? this.anonKey}`);
    const timeoutMs = init.timeoutMs ?? this.timeoutMs;
    const { signal, cleanup, timedOut, aborted } = composeSignal(init.signal, timeoutMs);
    try {
      return await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: init.method ?? 'GET',
        headers,
        body: init.body ?? undefined,
        signal,
      });
    } catch (error) {
      throw this.normalizeTransportError(error, timeoutMs, timedOut(), aborted());
    } finally {
      cleanup();
    }
  }

  private async fetchOnce<T>(path: string, init: RequestOptions): Promise<T> {
    const timeoutMs = init.timeoutMs ?? this.timeoutMs;
    const { signal, cleanup, timedOut, aborted } = composeSignal(init.signal, timeoutMs);

    try {
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: init.method ?? 'GET',
        headers: this.buildHeaders(init),
        body: init.body === undefined ? undefined : JSON.stringify(init.body),
        signal,
      });

      const body = await parseBody(response);

      if (!response.ok) {
        const retryAfterMs = parseRetryAfter(response.headers.get('Retry-After'));
        throw httpError(
          extractErrorMessage(body) ?? response.statusText ?? `HTTP ${response.status}`,
          response.status,
          body,
          retryAfterMs,
        );
      }

      return body as T;
    } catch (error) {
      throw this.normalizeTransportError(error, timeoutMs, timedOut(), aborted());
    } finally {
      cleanup();
    }
  }

  private buildHeaders(init: RequestOptions): Headers {
    const headers = new Headers(init.headers);
    const apiKey = init.apiKey ?? this.anonKey;
    headers.set('apikey', apiKey);

    if (init.auth !== false) {
      headers.set('Authorization', `Bearer ${init.bearerToken ?? this.session?.accessToken ?? apiKey}`);
    }

    if (init.body !== undefined) headers.set('Content-Type', 'application/json');

    return headers;
  }

  /** Whether this call may be auto-retried (idempotency, explicit or inferred). */
  private isIdempotent(init: RequestOptions): boolean {
    if (init.idempotent !== undefined) return init.idempotent;
    return IDEMPOTENT_METHODS.has((init.method ?? 'GET').toUpperCase());
  }

  /**
   * Returns the backoff delay (ms) before the next attempt, or `undefined` to
   * stop and rethrow. Non-idempotent calls never retry. Honors a server
   * `Retry-After` when present; otherwise exponential backoff + full jitter,
   * capped at `maxDelayMs`.
   */
  private retryDelay(
    error: unknown,
    idempotent: boolean,
    attempt: number,
    attempts: number,
  ): number | undefined {
    if (attempt >= attempts) return undefined;
    if (!idempotent) return undefined;
    if (!this.isRetryable(error)) return undefined;

    if (error instanceof MiniBaasRateLimitError && error.retryAfterMs !== undefined) {
      return Math.min(error.retryAfterMs, this.retry.maxDelayMs);
    }

    const base = this.retry.delayMs * 2 ** (attempt - 1);
    const capped = Math.min(base, this.retry.maxDelayMs);
    return Math.round(capped * (0.5 + Math.random() * 0.5)); // full-ish jitter
  }

  private isRetryable(error: unknown): boolean {
    if (error instanceof MiniBaasTimeoutError) return error.retryable;
    if (error instanceof MiniBaasNetworkError) return true;
    if (error instanceof MiniBaasError) return this.retry.retryOn.includes(error.status);
    return false;
  }

  /** Convert a thrown transport error into a typed MiniBaas error. */
  private normalizeTransportError(
    error: unknown,
    timeoutMs: number,
    timedOut: boolean,
    aborted: boolean,
  ): unknown {
    if (error instanceof MiniBaasError) return error; // already typed (e.g. httpError)
    if (isAbortError(error)) {
      if (timedOut) return new MiniBaasTimeoutError(timeoutMs, false);
      if (aborted) return new MiniBaasTimeoutError(timeoutMs, true);
      return new MiniBaasTimeoutError(timeoutMs, true);
    }
    return new MiniBaasNetworkError(transportMessage(error), error);
  }
}

function normalizeRetry(retry?: number | RetryOptions): ResolvedRetry {
  const defaults = {
    attempts: 3,
    delayMs: 250,
    maxDelayMs: 10_000,
    retryOn: [...RETRYABLE_STATUSES],
  };
  if (typeof retry === 'number') {
    return { ...defaults, attempts: retry };
  }
  return {
    attempts: retry?.attempts ?? defaults.attempts,
    delayMs: retry?.delayMs ?? defaults.delayMs,
    maxDelayMs: retry?.maxDelayMs ?? defaults.maxDelayMs,
    retryOn: retry?.retryOn ?? defaults.retryOn,
  };
}

/**
 * Compose an optional external `AbortSignal` with a per-call timeout into a
 * single signal. Returns the merged signal, a `cleanup()` to clear timers, and
 * predicates reporting *why* it aborted (timeout vs external).
 */
function composeSignal(
  external: AbortSignal | undefined,
  timeoutMs: number,
): {
  signal: AbortSignal;
  cleanup: () => void;
  timedOut: () => boolean;
  aborted: () => boolean;
} {
  const controller = new AbortController();
  let didTimeout = false;
  let didExternalAbort = false;

  const timer = timeoutMs > 0
    ? setTimeout(() => {
        didTimeout = true;
        controller.abort();
      }, timeoutMs)
    : undefined;

  const onExternalAbort = () => {
    didExternalAbort = true;
    controller.abort();
  };

  if (external) {
    if (external.aborted) {
      didExternalAbort = true;
      controller.abort();
    } else {
      external.addEventListener('abort', onExternalAbort, { once: true });
    }
  }

  return {
    signal: controller.signal,
    cleanup: () => {
      if (timer) clearTimeout(timer);
      if (external) external.removeEventListener('abort', onExternalAbort);
    },
    timedOut: () => didTimeout,
    aborted: () => didExternalAbort,
  };
}

/** Parse a `Retry-After` header (delta-seconds or HTTP-date) into ms. */
function parseRetryAfter(value: string | null): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const when = Date.parse(value);
  if (Number.isFinite(when)) return Math.max(0, when - Date.now());
  return undefined;
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

function transportMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  return 'network request failed';
}

function isAbortError(error: unknown): boolean {
  if (typeof DOMException !== 'undefined' && error instanceof DOMException) {
    return error.name === 'AbortError';
  }
  return error instanceof Error && error.name === 'AbortError';
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
