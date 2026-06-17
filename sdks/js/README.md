# @mini-baas/js

Product SDK for consuming mini-BaaS through the public gateway.

The SDK is intentionally designed as the public product API. Application code calls domain methods such as `auth.signIn()`, `from("users").select()`, `storage.presign()`, and `analytics.track()`; gateway routes and service endpoint details stay private inside the SDK.

The surface is **Supabase-shaped** on purpose — same `createClient`, `.from(...)`, `.auth`, `.storage.from(bucket)`, `.rpc()`. Coming from another BaaS? See the migration guides: [migrate-from-supabase](../wiki/migrate-from-supabase.md) (mostly a dependency swap) and [migrate-from-firebase](../wiki/migrate-from-firebase.md) (cross-paradigm).

## Use In This Workspace

This workspace uses the SDK through Docker-managed dependency volumes. Do not install it on the host for local development. Start the root stack instead:

```sh
docker compose up -d --build
```

External applications can consume the package from the registry using their normal package manager.

## Create a client

```ts
import { createClient } from "@mini-baas/js";

const baas = createClient({
  url: "https://api.example.com",
  anonKey: "public-anon-key",
  defaultDatabaseId: "default",
  timeoutMs: 15_000,
  retry: {
    attempts: 3,
    delayMs: 250,
  },
});
```

## Auth

```ts
const session = await baas.auth.signIn({
  email: "user@example.com",
  password: "secret",
});

const user = await baas.auth.getUser();

await baas.auth.refreshSession(session.refresh_token);
await baas.auth.signOut();
```

Browser clients persist sessions automatically in `localStorage`. Server-side clients use memory storage by default.

To disable persistence:

```ts
const baas = createClient({
  url: "https://api.example.com",
  anonKey: "public-anon-key",
  persistSession: false,
});
```

To plug a custom storage adapter:

```ts
const baas = createClient({
  url: "https://api.example.com",
  anonKey: "public-anon-key",
  storage: {
    load: () => readSessionFromCookies(),
    save: (session) => writeSessionToCookies(session),
    clear: () => clearSessionCookie(),
  },
});
```

## Resource API

```ts
type User = {
  id: string;
  email: string;
  created_at: string;
};

const users = await baas
  .from<User>("users")
  .select({ email: "demo@example.com" });

const inserted = await baas
  .from<User>("users")
  .insert({ email: "new@example.com" });

await baas
  .from<User>("users")
  .update({ email: "updated@example.com" }, { id: inserted.id });

await baas.from<User>("users").delete({ id: inserted.id });
```

## Domain APIs

```ts
const report = await baas.query.run<{ total: number }>({
  action: "aggregate",
  resource: "orders",
  payload: { metric: "total" },
});

const upload = await baas.storage.presign({
  bucket: "avatars",
  key: "users/123.png",
  method: "PUT",
  contentType: "image/png",
});

await baas.analytics.track("user_signed_in", {
  source: "web",
});

const wsUrl = baas.realtimeUrl("project-events");
```

### Transactions

Single-mount atomic write batch — all ops commit together or none do. The
target engine must be transactional (postgresql/mysql).

```ts
await baas.txn.execute({
  databaseId: "default",
  operations: [
    { op: "insert", resource: "nodes", data: { id: "n1", label: "A" } },
    { op: "insert", resource: "edges", data: { from: "n1", to: "n2" } },
  ],
});
```

### Schema introspection & DDL

Engine-agnostic live-database mode — one call describes any mount (normalized
column types + the engine's live capabilities), one call applies a single
schema operation. Engines without the surface (redis/http) reject with 422
`unsupported_capability`; data-incompatible `alter_column_type` rejects with 409.

```ts
const schema = await baas.schema.describe(dbId);
// → { dbId, engine: "postgresql", capabilities: { schema_ddl: true, ... }, tables: [...] }

await baas.schema.ddl(dbId, {
  op: "add_column",
  table: "todos",
  column: { name: "done", normalized_type: "boolean", nullable: false, default: "false" },
});

// Destructive ops (drop_column / drop_table) require confirm: true — both at
// compile time and client-side before any request is sent:
await baas.schema.ddl(dbId, { op: "drop_table", table: "scratch", confirm: true });
```

Realtime row changes for a table travel on the `table:<dbId>:<table>` topic:

```ts
const wsUrl = baas.realtimeUrl(`table:${dbId}:todos`);
```

### Edge functions

```ts
await baas.functions.deploy({ name: "hello", code: "export default (req) => ({ status: 200, body: { ok: true } });" });
const fns = await baas.functions.list();
const out = await baas.functions.invoke<{ ok: boolean }>("hello", { name: "world" });
```

## Admin-only / server-side clients

The following clients call internal-only gateway routes (`ip-restriction` +
service token) and **must not be used from a browser**. Construct the client with
a `serviceRoleKey`; calling these without it throws.

```ts
const admin = createClient({ url, anonKey, serviceRoleKey: process.env.SERVICE_ROLE_KEY });

// Webhooks (secrets are write-only, never echoed):
await admin.webhooks.create({ name: "audit", url: "https://hooks.example/x", secret: "s3cr3t" });
await admin.webhooks.list();

// Tenants + declarative provision:
await admin.admin.tenants.create({ id: "acme", name: "Acme" });
await admin.admin.tenants.bootstrap("acme", { seed_roles: true });
await admin.admin.provision({ tenant: "acme", mounts: [{ engine: "postgresql", name: "db", connection_string: "postgres://..." }] });

// Per-tenant schema migration (Rust data plane):
await admin.admin.migrate.run({
  identity: { tenant_id: "acme", user_id: "ops", source: "service_token", roles: ["service_role"] },
  mount: { id: "m1", tenant_id: "acme", engine: "postgresql", name: "db", credential_ref: { provider: "inline", reference: "db", version: "1" }, inline_dsn: "postgres://..." },
  name: "create-schema",
  statements: ["CREATE SCHEMA IF NOT EXISTS tenant_acme"],
});
```

## Architecture

```text
Application code
  ↓
Product SDK domains: auth / from / query / schema / storage / analytics / realtime / txn / functions
  (+ admin-only: webhooks / admin.tenants / admin.provision / admin.migrate)
  ↓
Private SDK core: session / retry / timeout / HTTP transport / route map
  ↓
Public API Gateway
  ↓
Private mini-BaaS microservices
```

Public application code should never depend on gateway paths. Those paths are private implementation details owned by the SDK.

## Current v2 scope

- Domain-first public API.
- Private route map and HTTP transport layer.
- Resource-style `from(resource)` API.
- Generic response typing.
- Session persistence with browser, memory, or custom adapters.
- Refresh-token helper.
- Retry and timeout handling.
