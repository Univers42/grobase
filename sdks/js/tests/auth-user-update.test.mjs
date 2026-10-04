// The SDK's two user-update calls use the verbs GoTrue serves. GoTrue v2.188.1
// (the version infra/docker/services/gotrue builds) routes /user as GET + PUT
// and /admin/users/{id} as GET + PUT + DELETE, so POST and PATCH answer 405.
// Transport mocked via the `fetch` option; no network.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '../dist/index.js';

const BASE_URL = 'https://baas.test';

function recordingClient(options = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), method: init?.method });
    return new Response(JSON.stringify({ id: 'u1' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };
  const client = createClient({
    url: BASE_URL,
    anonKey: 'anon-key',
    persistSession: false,
    fetch: fetchImpl,
    ...options,
  });
  return { client, calls };
}

test('auth.updateUser sends PUT /auth/v1/user', async () => {
  const { client, calls } = recordingClient();
  await client.auth.updateUser({ data: { theme: 'dark' } }, 'user-jwt');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'PUT');
  assert.equal(calls[0].url, `${BASE_URL}/auth/v1/user`);
});

test('auth.admin.updateUser sends PUT /auth/v1/admin/users/{id}', async () => {
  const { client, calls } = recordingClient({ serviceRoleKey: 'service-key' });
  await client.auth.admin.updateUser('u 1', { email_confirm: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'PUT');
  assert.equal(calls[0].url, `${BASE_URL}/auth/v1/admin/users/u%201`);
});
