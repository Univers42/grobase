/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   admin-migrate.test.mjs                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 12:45:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 12:45:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// G1f (ADR 0008): Kong forwards /admin/v1/migrate to tenant-control's relay,
// which admits the request only when `apikey` equals KONG_SERVICE_API_KEY
// (= SERVICE_ROLE_KEY, scripts/env/generate-env.sh) and replaces `identity`
// server-side. The relay half is admin_relay_test.go (kong_service_key arm);
// this pins the SDK half, so admin.migrate.run keeps working unchanged.
// Run against the BUILT output (`npm run build` first).

import test from "node:test";
import assert from "node:assert/strict";
import { createClient, MiniBaasError } from "../dist/index.js";

const BASE_URL = "https://baas.test";
const SERVICE_KEY = "service-role-key";

function mockTransport(handler = () => ({})) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    const { status = 200, body = {} } = handler(String(url), init);
    return new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  };
  return { calls, fetchImpl };
}

function makeClient(
  transport,
  { serviceRoleKey } = { serviceRoleKey: SERVICE_KEY },
) {
  return createClient({
    url: BASE_URL,
    anonKey: "anon-key",
    serviceRoleKey,
    persistSession: false,
    fetch: transport.fetchImpl,
  });
}

const input = {
  identity: {
    tenant_id: "t1",
    user_id: "caller-declared",
    roles: ["authenticated"],
  },
  mount: { tenant_id: "t1", engine: "postgresql", isolation: "schema" },
  name: "2026_10_30_add_notes",
  statements: ["CREATE TABLE notes (id int)"],
};

test("admin.migrate.run POSTs the input unchanged to /admin/v1/migrate with the service key", async () => {
  const transport = mockTransport(() => ({ body: { applied: true } }));
  const result = await makeClient(transport).admin.migrate.run(input);
  assert.deepEqual(result, { applied: true });
  assert.equal(transport.calls.length, 1);
  const { url, init } = transport.calls[0];
  assert.equal(url, `${BASE_URL}/admin/v1/migrate`);
  assert.equal(init.method, "POST");
  const headers = new Headers(init.headers);
  assert.equal(headers.get("apikey"), SERVICE_KEY);
  assert.equal(headers.get("authorization"), `Bearer ${SERVICE_KEY}`);
  // The relay overwrites `identity`; every other member must arrive as sent.
  assert.deepEqual(JSON.parse(init.body), input);
});

// requireAdminKey throws before any promise exists, so this is a sync throw.
test("admin.migrate.run refuses to send without a service role key", () => {
  const transport = mockTransport();
  assert.throws(
    () => makeClient(transport, {}).admin.migrate.run(input),
    /Missing service role key for admin migrate/,
  );
  assert.equal(transport.calls.length, 0);
});

test("admin.migrate.run surfaces the relay 401 as MiniBaasError", async () => {
  const transport = mockTransport(() => ({
    status: 401,
    body: {
      error: "unauthorized",
      message: "service token or service API key required",
    },
  }));
  await assert.rejects(
    () => makeClient(transport).admin.migrate.run(input),
    (err) => err instanceof MiniBaasError && err.status === 401,
  );
});
