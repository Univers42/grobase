/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   routes.ts                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:37:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

export const routes = {
  auth: {
    token: (grantType: 'password' | 'refresh_token') => `/auth/v1/token?grant_type=${grantType}`,
    signup: '/auth/v1/signup',
    recover: '/auth/v1/recover',
    verify: '/auth/v1/verify',
    logout: '/auth/v1/logout',
    user: '/auth/v1/user',
    authorize: '/auth/v1/authorize',
    factors: '/auth/v1/factors',
    factor: (id: string) => `/auth/v1/factors/${encodeURIComponent(id)}`,
    factorChallenge: (id: string) => `/auth/v1/factors/${encodeURIComponent(id)}/challenge`,
    factorVerify: (id: string) => `/auth/v1/factors/${encodeURIComponent(id)}/verify`,
    adminUsers: '/auth/v1/admin/users',
    adminUser: (id: string) => `/auth/v1/admin/users/${encodeURIComponent(id)}`,
    adminGenerateLink: '/auth/v1/admin/generate_link',
  },
  rest: {
    root: '/rest/v1/',
    resource: (resource: string) => `/rest/v1/${encodePath(resource)}`,
    rpc: (name: string) => `/rest/v1/rpc/${encodePath(name)}`,
  },
  query: {
    execute: '/query/v1/execute',
    txn: '/query/v1/txn',
    engines: '/query/v1/engines',
    schema: (dbId: string) => `/query/v1/${encodeURIComponent(dbId)}/schema`,
    schemaDdl: (dbId: string) => `/query/v1/${encodeURIComponent(dbId)}/schema/ddl`,
  },
  graphql: {
    // PostgREST's pg_graphql endpoint, fronted by Kong (strip_path → /graphql).
    root: '/graphql/v1',
  },
  webhooks: {
    root: '/admin/v1/webhooks',
    one: (id: string) => `/admin/v1/webhooks/${encodeURIComponent(id)}`,
    deliveries: (id: string) => `/admin/v1/webhooks/${encodeURIComponent(id)}/deliveries`,
  },
  tenants: {
    // NOTE (pre-existing mismatch, do NOT fix here): these admin routes are
    // prefixed `/admin/v1/*`, but the Go control-plane server actually serves
    // the tenant registry under `/v1/*`. The admin client still points here for
    // back-compat — flag as a separate cleanup. The self-service surface below
    // (`tenantsSelf`) uses the REAL server paths (`/v1/tenants/me*`).
    root: '/admin/v1/tenants',
    one: (id: string) => `/admin/v1/tenants/${encodeURIComponent(id)}`,
    bootstrap: (id: string) => `/admin/v1/tenants/${encodeURIComponent(id)}/bootstrap`,
    provision: '/admin/v1/provision',
  },
  // B4a — tenant self-service control plane. Real server paths under `/v1/*`.
  // Callable with a tenant API key OR a GoTrue user JWT; the server resolves
  // "me" from the bearer credential.
  tenantsSelf: {
    me: '/v1/tenants/me',
    usage: (period?: string) =>
      `/v1/tenants/me/usage${period ? `?period=${encodeURIComponent(period)}` : ''}`,
    keys: '/v1/tenants/me/keys',
    key: (keyId: string) => `/v1/tenants/me/keys/${encodeURIComponent(keyId)}`,
    // B7/builder — per-tenant DYNAMIC BUILDER (flag BUILDER_ENABLED on the
    // server; routes 404 when OFF). Tenant resolved from the caller credential
    // (no `{id}` → no cross-tenant by construction). `mount(id)` DELETE is
    // caller-scoped server-side (`AND tenant_id = $caller`).
    mounts: '/v1/tenants/me/mounts',
    mount: (id: string) => `/v1/tenants/me/mounts/${encodeURIComponent(id)}`,
    entitlements: '/v1/tenants/me/entitlements',
    builder: '/v1/tenants/me/builder',
  },
  migrate: {
    run: '/admin/v1/migrate',
  },
  functions: {
    root: '/functions/v1',
    one: (name: string) => `/functions/v1/${encodeURIComponent(name)}`,
    invoke: (name: string) => `/functions/v1/${encodeURIComponent(name)}/invoke`,
    // ── A2 Functions DX: triggers / schedules / secrets (admin surface) ───────
    triggers: '/admin/v1/function-triggers',
    trigger: (id: string) => `/admin/v1/function-triggers/${encodeURIComponent(id)}`,
    schedules: '/admin/v1/function-schedules',
    schedule: (id: string) => `/admin/v1/function-schedules/${encodeURIComponent(id)}`,
    secrets: '/admin/v1/function-secrets',
    secret: (key: string) => `/admin/v1/function-secrets/${encodeURIComponent(key)}`,
  },
  storage: {
    sign: (bucket: string, key: string) =>
      `/storage/v1/sign/${encodeURIComponent(bucket)}/${encodePath(key)}`,
    object: (bucket: string, key: string) =>
      `/storage/v1/object/${encodeURIComponent(bucket)}/${encodePath(key)}`,
    // A1 transforms: same owner-scoped object GET with a ?width=&height=&format=
    // query. The server returns the original bytes verbatim when
    // STORAGE_TRANSFORMS_ENABLED is OFF or no transform param is present.
    transform: (bucket: string, key: string, q: string) =>
      `/storage/v1/object/${encodeURIComponent(bucket)}/${encodePath(key)}${q ? `?${q}` : ''}`,
    list: (bucket: string, prefix?: string) =>
      `/storage/v1/list/${encodeURIComponent(bucket)}${prefix ? `?prefix=${encodeURIComponent(prefix)}` : ''}`,
    buckets: '/storage/v1/bucket',
    bucket: (name: string) => `/storage/v1/bucket/${encodeURIComponent(name)}`,
  },
  analytics: {
    events: '/analytics/v1/events',
  },
  realtime: {
    channel: (channel: string) => `/realtime/v1/ws?channel=${encodeURIComponent(channel)}`,
    // Topic name (NOT a URL) for one table's `row_changed` stream. Compose it
    // with `client.realtimeUrl(...)` or send it in a SUBSCRIBE frame.
    tableChannel: (dbId: string, table: string) => `table:${dbId}:${table}`,
  },
} as const;

function encodePath(value: string): string {
  return value
    .split('/')
    .filter(Boolean)
    .map((part) => encodeURIComponent(part))
    .join('/');
}
