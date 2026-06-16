/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.ts                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//
// Typed error hierarchy (Track-E SDK hardening).
//
// All errors descend from `MiniBaasError` so existing `instanceof MiniBaasError`
// / `err.status` call sites keep working. HTTP failures resolve to a *specific*
// subclass so callers can branch on type rather than re-inspecting `status`:
//
//   try { await client.from('t').insert(row); }
//   catch (e) {
//     if (e instanceof MiniBaasConflictError) { /* 409 */ }
//     else if (e instanceof MiniBaasServerError) { /* 5xx */ }
//     else if (e instanceof MiniBaasTimeoutError) { /* aborted */ }
//   }
//
// `MiniBaasError` keeps its original 3-arg shape `(message, status, body)` so it
// is still directly constructible the way `http.ts` did before this change.
//

/** Base class for every error the SDK throws. Carries the HTTP `status` (0 for
 *  non-HTTP failures like network/timeout) and the parsed server `body`. */
export class MiniBaasError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: unknown,
  ) {
    super(message);
    this.name = 'MiniBaasError';
  }

  /** True for the status codes that are safe to retry on idempotent requests. */
  get retryable(): boolean {
    return RETRYABLE_STATUSES.has(this.status);
  }
}

/** Default set of retryable HTTP statuses (idempotent requests only). */
export const RETRYABLE_STATUSES: ReadonlySet<number> = new Set([408, 425, 429, 500, 502, 503, 504]);

/** Any 4xx that is not a more specific subclass below. */
export class MiniBaasClientError extends MiniBaasError {
  constructor(message: string, status: number, body: unknown) {
    super(message, status, body);
    this.name = 'MiniBaasClientError';
  }
}

/** 400 — malformed request / validation failure. */
export class MiniBaasBadRequestError extends MiniBaasClientError {
  constructor(message: string, body: unknown) {
    super(message, 400, body);
    this.name = 'MiniBaasBadRequestError';
  }
}

/** 401 — missing / invalid credentials. */
export class MiniBaasUnauthorizedError extends MiniBaasClientError {
  constructor(message: string, body: unknown) {
    super(message, 401, body);
    this.name = 'MiniBaasUnauthorizedError';
  }
}

/** 403 — authenticated but not permitted (ABAC/RLS denial). */
export class MiniBaasForbiddenError extends MiniBaasClientError {
  constructor(message: string, body: unknown) {
    super(message, 403, body);
    this.name = 'MiniBaasForbiddenError';
  }
}

/** 404 — resource not found. */
export class MiniBaasNotFoundError extends MiniBaasClientError {
  constructor(message: string, body: unknown) {
    super(message, 404, body);
    this.name = 'MiniBaasNotFoundError';
  }
}

/** 409 — integrity / uniqueness conflict. */
export class MiniBaasConflictError extends MiniBaasClientError {
  constructor(message: string, body: unknown) {
    super(message, 409, body);
    this.name = 'MiniBaasConflictError';
  }
}

/** 402 / 429 — quota exceeded or rate limited. Carries the `Retry-After`
 *  hint (in milliseconds) when the server supplied one. */
export class MiniBaasRateLimitError extends MiniBaasClientError {
  constructor(
    message: string,
    status: number,
    body: unknown,
    readonly retryAfterMs?: number,
  ) {
    super(message, status, body);
    this.name = 'MiniBaasRateLimitError';
  }
}

/** Any 5xx server-side failure. */
export class MiniBaasServerError extends MiniBaasError {
  constructor(message: string, status: number, body: unknown) {
    super(message, status, body);
    this.name = 'MiniBaasServerError';
  }
}

/** Transport-level failure (DNS, connection reset, fetch threw). `status` is 0. */
export class MiniBaasNetworkError extends MiniBaasError {
  constructor(message: string, readonly cause?: unknown) {
    super(message, 0, undefined);
    this.name = 'MiniBaasNetworkError';
  }

  /** Network failures are always retryable on idempotent requests. */
  get retryable(): boolean {
    return true;
  }
}

/** Request aborted because the (timeout or external) signal fired. `status` is 0. */
export class MiniBaasTimeoutError extends MiniBaasError {
  constructor(
    readonly timeoutMs: number,
    /** True when an *external* signal aborted the call (not the timeout). */
    readonly external = false,
  ) {
    super(
      external
        ? 'MiniBaas request was aborted'
        : `MiniBaas request timed out after ${timeoutMs}ms`,
      0,
      undefined,
    );
    this.name = 'MiniBaasTimeoutError';
  }

  /** Timeouts are retryable on idempotent requests (the server may be slow,
   *  not wrong); an external abort is never retried. */
  get retryable(): boolean {
    return !this.external;
  }
}

/**
 * Map an HTTP error `response`/`body` to the most specific typed error.
 * `retryAfterMs` is parsed from the `Retry-After` header by the caller.
 */
export function httpError(
  message: string,
  status: number,
  body: unknown,
  retryAfterMs?: number,
): MiniBaasError {
  switch (status) {
    case 400:
      return new MiniBaasBadRequestError(message, body);
    case 401:
      return new MiniBaasUnauthorizedError(message, body);
    case 402:
      return new MiniBaasRateLimitError(message, status, body, retryAfterMs);
    case 403:
      return new MiniBaasForbiddenError(message, body);
    case 404:
      return new MiniBaasNotFoundError(message, body);
    case 409:
      return new MiniBaasConflictError(message, body);
    case 429:
      return new MiniBaasRateLimitError(message, status, body, retryAfterMs);
    default:
      break;
  }
  if (status >= 500) return new MiniBaasServerError(message, status, body);
  if (status >= 400) return new MiniBaasClientError(message, status, body);
  // Non-error status reaching here means the caller misclassified; preserve it.
  return new MiniBaasError(message, status, body);
}
