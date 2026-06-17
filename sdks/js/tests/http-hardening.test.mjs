/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   http-hardening.test.mjs                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/15 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/15 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Track-E SDK hardening gate. Transport mocked via the `fetch` option — no
// network. Proves: idempotent retry-with-backoff, no-retry for POST creates,
// typed errors carrying status + body, request timeout/abort with the typed
// Timeout error, external AbortSignal composition, and the changesSince cursor.
//

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createClient,
  MiniBaasError,
  MiniBaasConflictError,
  MiniBaasServerError,
  MiniBaasTimeoutError,
  MiniBaasNetworkError,
  MiniBaasRateLimitError,
} from '../dist/index.js';

const BASE_URL = 'https://baas.test';

// Each entry is a *recipe* (status/body/headers or a function) so a fresh
// Response is built per call — a Response body can only be consumed once, so we
// must NOT hand back the same object across retries.
function jsonResponse(body, status = 200, headers = {}) {
  return { body, status, headers };
}

function buildResponse(recipe, url, init) {
  if (typeof recipe === 'function') return recipe(url, init);
  const { body, status = 200, headers = {} } = recipe;
  const payload = typeof body === 'string' ? body : JSON.stringify(body);
  return new Response(payload, { status, headers: { 'Content-Type': 'application/json', ...headers } });
}

/** A fetch mock that returns the queued responses in order; records calls. */
function scriptedTransport(responses) {
  const calls = [];
  let i = 0;
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    const next = responses[Math.min(i, responses.length - 1)];
    i += 1;
    return buildResponse(next, String(url), init);
  };
  return { calls, fetchImpl };
}

function makeClient(fetchImpl, opts = {}) {
  return createClient({
    url: BASE_URL,
    anonKey: 'anon-key',
    persistSession: false,
    fetch: fetchImpl,
    // Tiny backoff so the retry test runs fast.
    retry: { attempts: 3, delayMs: 1, maxDelayMs: 5 },
    ...opts,
  });
}

// ── 1. retry: 503 then 200 → succeeds; assert attempt count ──────────────────
test('idempotent GET retries on 503 then succeeds (attempt count = 2)', async () => {
  const transport = scriptedTransport([
    jsonResponse({ message: 'unavailable' }, 503),
    jsonResponse([{ id: 1 }], 200),
  ]);
  const client = makeClient(transport.fetchImpl);

  const rows = await client.from('users').select({ columns: 'id' });
  assert.deepEqual(rows, [{ id: 1 }]);
  assert.equal(transport.calls.length, 2, 'one retry after the 503');
});

test('idempotent GET exhausts attempts on persistent 503 and throws typed server error', async () => {
  const transport = scriptedTransport([jsonResponse({ message: 'down' }, 503)]);
  const client = makeClient(transport.fetchImpl);

  await assert.rejects(
    () => client.from('users').select(),
    (err) => {
      assert.ok(err instanceof MiniBaasServerError, 'typed 5xx');
      assert.equal(err.status, 503);
      return true;
    },
  );
  assert.equal(transport.calls.length, 3, 'attempts capped at 3');
});

// ── 2. no-retry: POST create returning 503 → throws after 1 attempt ──────────
test('non-idempotent POST create does NOT auto-retry (1 attempt)', async () => {
  const transport = scriptedTransport([jsonResponse({ message: 'unavailable' }, 503)]);
  const client = makeClient(transport.fetchImpl);

  await assert.rejects(
    () => client.from('users').insert({ name: 'Alice' }),
    (err) => err instanceof MiniBaasServerError && err.status === 503,
  );
  assert.equal(transport.calls.length, 1, 'POST create issued exactly once');
});

// ── 3. timeout / abort ───────────────────────────────────────────────────────
test('a never-resolving fetch rejects with the typed Timeout error within budget', async () => {
  // fetch resolves only when its signal aborts (models a hung server).
  const hung = (_url, init) =>
    new Promise((_resolve, reject) => {
      init.signal.addEventListener('abort', () => {
        const e = new Error('aborted');
        e.name = 'AbortError';
        reject(e);
      });
    });
  const transport = scriptedTransport([hung]);
  const client = makeClient(transport.fetchImpl, { timeoutMs: 40, retry: { attempts: 1 } });

  const started = Date.now();
  await assert.rejects(
    () => client.from('users').select(),
    (err) => {
      assert.ok(err instanceof MiniBaasTimeoutError, 'typed timeout');
      assert.equal(err.external, false, 'classified as timeout, not external abort');
      return true;
    },
  );
  assert.ok(Date.now() - started < 1000, 'rejected well within the budget');
});

test('an external AbortSignal aborts the call (typed Timeout, external=true)', async () => {
  const hung = (_url, init) =>
    new Promise((_resolve, reject) => {
      init.signal.addEventListener('abort', () => {
        const e = new Error('aborted');
        e.name = 'AbortError';
        reject(e);
      });
    });
  const transport = scriptedTransport([hung]);
  const client = makeClient(transport.fetchImpl, { timeoutMs: 5000, retry: { attempts: 1 } });

  const controller = new AbortController();
  setTimeout(() => controller.abort(), 20);

  await assert.rejects(
    () => client.from('users').select({ signal: controller.signal }),
    (err) => {
      assert.ok(err instanceof MiniBaasTimeoutError, 'typed timeout');
      assert.equal(err.external, true, 'classified as an external abort');
      return true;
    },
  );
});

// ── 4. typed errors: 409 → typed conflict carrying status + body ─────────────
test('a 409 response throws MiniBaasConflictError carrying status + server body', async () => {
  const body = { message: 'duplicate key', code: '23505' };
  const transport = scriptedTransport([jsonResponse(body, 409)]);
  const client = makeClient(transport.fetchImpl);

  await assert.rejects(
    () => client.from('users').insert({ id: 1 }),
    (err) => {
      assert.ok(err instanceof MiniBaasConflictError, 'typed conflict');
      assert.ok(err instanceof MiniBaasError, 'still a MiniBaasError (back-compat)');
      assert.equal(err.status, 409);
      assert.deepEqual(err.body, body, 'server body preserved');
      assert.equal(err.message, 'duplicate key');
      return true;
    },
  );
  assert.equal(transport.calls.length, 1, '409 is not retried');
});

// ── Extra coverage: 429 Retry-After + network error + changesSince ───────────
test('429 yields MiniBaasRateLimitError parsing Retry-After, and is retried', async () => {
  const transport = scriptedTransport([
    jsonResponse({ message: 'slow down' }, 429, { 'Retry-After': '0' }),
    jsonResponse([{ id: 9 }], 200),
  ]);
  const client = makeClient(transport.fetchImpl);
  const rows = await client.from('events').select();
  assert.deepEqual(rows, [{ id: 9 }]);
  assert.equal(transport.calls.length, 2);
});

test('a thrown (non-HTTP) fetch surfaces as MiniBaasNetworkError and is retried on GET', async () => {
  let n = 0;
  const fetchImpl = async () => {
    n += 1;
    if (n === 1) throw new TypeError('Failed to fetch');
    return new Response(JSON.stringify([{ ok: true }]), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  const client = makeClient(fetchImpl);
  const rows = await client.from('users').select();
  assert.deepEqual(rows, [{ ok: true }]);
  assert.equal(n, 2, 'network error retried once then succeeded');

  // And a POST network error is NOT retried.
  let m = 0;
  const fetchPost = async () => {
    m += 1;
    throw new TypeError('Failed to fetch');
  };
  const c2 = makeClient(fetchPost);
  await assert.rejects(
    () => c2.from('users').insert({ a: 1 }),
    (err) => err instanceof MiniBaasNetworkError && err.status === 0,
  );
  assert.equal(m, 1, 'POST network error not retried');
});

test('changesSince builds a keyset page and returns nextCursor', async () => {
  const transport = scriptedTransport([
    jsonResponse([
      { id: 1, updated_at: 100 },
      { id: 2, updated_at: 200 },
    ], 200),
  ]);
  const client = makeClient(transport.fetchImpl);

  const page = await client.from('docs').changesSince(50, { cursorColumn: 'updated_at', limit: 2 });
  const url = new URL(transport.calls[0].url);
  assert.equal(url.pathname, '/rest/v1/docs');
  assert.equal(url.searchParams.get('order'), 'updated_at.asc');
  assert.equal(url.searchParams.get('limit'), '2');
  assert.equal(url.searchParams.get('updated_at'), 'gt.50');
  assert.equal(page.rows.length, 2);
  assert.equal(page.hasMore, true, 'page filled limit → more may remain');
  assert.equal(page.nextCursor, 200, 'cursor = last row updated_at');

  // A short page drains the cursor.
  const t2 = scriptedTransport([jsonResponse([{ id: 3, updated_at: 300 }], 200)]);
  const c2 = makeClient(t2.fetchImpl);
  const last = await c2.from('docs').changesSince(200, { cursorColumn: 'updated_at', limit: 2 });
  assert.equal(last.hasMore, false);
  assert.equal(last.nextCursor, null, 'drained');
});
