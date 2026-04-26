# SDK v2 Design

The JavaScript SDK is the product-facing API for mini-BaaS. It must feel like a platform SDK, not like a thin wrapper around backend routes.

## Goals

- Hide gateway and service endpoint paths from application code.
- Separate public domain methods from private transport mechanics.
- Provide a Supabase-like resource API for common data operations.
- Support professional auth session handling: persistence, refresh, and explicit clearing.
- Add production HTTP behavior: timeout, retry, structured errors.
- Keep all traffic going through the public API gateway.

## Layering

```text
Frontend / partner backend
  ↓
@mini-baas/js public domains
  - auth.signIn()
  - auth.refreshSession()
  - from("users").select()
  - query.run()
  - storage.presign()
  - analytics.track()
  - realtimeUrl()
  ↓
Private SDK core
  - route map
  - HTTP client
  - retry / timeout
  - error normalization
  - session persistence
  ↓
Kong gateway
  ↓
Private BaaS microservices
```

## Public API shape

### Auth

```ts
await baas.auth.signIn({ email, password });
await baas.auth.refreshSession();
await baas.auth.getUser();
await baas.auth.signOut();
```

### Resource data API

```ts
type User = { id: string; email: string };

const users = await baas.from<User>("users").select({ active: true });
const user = await baas.from<User>("users").insert({ email: "a@b.com" });
await baas.from<User>("users").update({ email: "c@d.com" }, { id: user.id });
await baas.from<User>("users").delete({ id: user.id });
```

### Advanced query API

```ts
const total = await baas.query.run<{ total: number }>({
  action: "aggregate",
  resource: "orders",
  payload: { metric: "total" },
});
```

## Private implementation rules

- Route paths live in the SDK private core only.
- Public docs and app examples should not mention backend paths.
- Domain clients should receive an internal HTTP client, not construct URLs directly.
- The SDK may preserve compatibility aliases, but new app code should use domain verbs.

## Session strategy

- Browser default: persist session in `localStorage`.
- Server/default fallback: memory storage.
- Advanced consumers can inject a storage adapter for cookies, encrypted storage, mobile storage, or test harnesses.
- `signIn()` stores the normalized session automatically.
- `refreshSession()` updates the stored access and refresh tokens.
- `signOut()` clears stored session state.

## Transport strategy

- Default timeout: 15 seconds.
- Default retries: transient network failures and retryable HTTP statuses.
- Errors are normalized to `MiniBaasError` or `MiniBaasTimeoutError`.
- API keys and bearer tokens are injected by the private HTTP layer.

## Current implementation status

Implemented in [packages/sdk-js](../packages/sdk-js/README.md):

- `MiniBaasClient` public facade.
- Domain clients for auth, query, storage, and analytics.
- Resource builder through `baas.from(resource)`.
- Private route map under SDK core.
- Private HTTP client with retry, timeout, and normalized errors.
- Browser/memory/custom session persistence.
- Generic response typing for `from()` and `query.run()`.

## Next SDK v3 candidates

- Schema-generated TypeScript types.
- Zod-compatible response validation hooks.
- React hooks package.
- SSR helper package for cookie-based auth.
- Realtime channel abstraction instead of raw WebSocket URL creation.
- Upload/download helpers built on top of signed URLs.
