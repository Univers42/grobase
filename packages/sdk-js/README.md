# @mini-baas/js

Product SDK for consuming mini-BaaS through the public gateway.

The SDK is intentionally designed as the public product API. Application code calls domain methods such as `auth.signIn()`, `from("users").select()`, `storage.presign()`, and `analytics.track()`; gateway routes and service endpoint details stay private inside the SDK.

## Install

```sh
npm install @mini-baas/js
```

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

## Architecture

```text
Application code
  ↓
Product SDK domains: auth / from / query / storage / analytics / realtime
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
