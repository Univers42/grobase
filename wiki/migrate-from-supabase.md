# Migrate from Supabase to Grobase

Grobase's client SDK (`@mini-baas/js`) is **deliberately Supabase-shaped**: same
`createClient`, same `.from(...).select()/.insert()`, same `.auth`, same
`.storage.from(bucket)`, same `.rpc()`. For most apps the migration is a
**dependency swap plus a base-URL change** — your query, auth, and storage code
stays recognisable.

This guide maps the surfaces one-to-one, then shows the two on-ramps:

1. **Lift-and-shift** — stand up Grobase, recreate your schema, repoint the SDK.
2. **Wrap-your-existing-Postgres** (`tenant_owned`) — point Grobase at the
   Postgres you already run and serve it through the uniform API **without
   copying a single row**. This is the differentiator Supabase can't offer.

> Honesty note: where a Supabase feature has no Grobase equivalent yet, this
> guide says so plainly and links the tracking row in
> [`competitive-matrix.md`](competitive-matrix.md). Don't migrate a feature you
> depend on until its row is at parity.

---

## 1. The one-line conceptual map

| Supabase | Grobase | Notes |
|---|---|---|
| `supabase-js` (`@supabase/supabase-js`) | `@mini-baas/js` | Ships in-repo (`apps/baas/sdk`) + as a git/file dep — not npm. |
| Project URL | Gateway URL (`http://localhost:8000` self-host) | Kong is the single public door, same as Supabase's Kong. |
| `anon` key | `anonKey` (the gateway public API key) | Self-host: `KONG_PUBLIC_API_KEY` in `.env`. |
| `service_role` key | `serviceRoleKey` | Same "bypasses RLS / admin" semantics; never ship to a browser. |
| PostgREST (`/rest/v1`) | PostgREST (`/rest/v1`) | **Identical** — Grobase vendors PostgREST. |
| GoTrue (`/auth/v1`) | GoTrue (`/auth/v1`) | **Identical** — Grobase vendors GoTrue. |
| Storage (`/storage/v1`) | storage-router (`/storage/v1`) | Supabase-shaped API over MinIO/S3. |
| Realtime (`/realtime/v1`) | Rust realtime (`/realtime/v1`) | CDC over WebSocket; see §6. |
| Edge Functions (Deno) | Functions (Deno) (`/functions/v1`) | See §7. |
| Row Level Security | Row Level Security **+ per-request tenant isolation** | Same RLS; Grobase adds dense multi-tenancy on top. |

Because Grobase vendors **the same PostgREST and the same GoTrue**, the REST and
auth wire protocols are not "compatible-ish" — they are the same servers. The
SDK differences below are ergonomic, not semantic.

---

## 2. Install + client construction

```diff
- import { createClient } from '@supabase/supabase-js'
- const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
+ import { createClient } from '@mini-baas/js'
+ const client = createClient({ url: BAAS_URL, anonKey: BAAS_ANON_KEY })
```

The **only** structural difference: `createClient` takes a single options object
(`{ url, anonKey }`), not two positional args. Everything downstream is the same
shape.

Install (no npm registry — distribution is Docker Hub + this repo by design):

```sh
npm install ./apps/baas/sdk
# or straight from git:
npm install git+https://github.com/Univers42/groot.git#main:apps/baas/sdk
```

---

## 3. Database queries (`.from(...)`)

The options-object form is a drop-in; the fluent form mirrors `supabase-js`
exactly (call `.query()` to enter the chain):

```ts
// supabase-js
const { data } = await supabase
  .from('todos').select('*').eq('done', false).order('created_at').limit(10)

// @mini-baas/js — fluent (identical chain, via .query())
const data = await client
  .from('todos').query().select('*').eq('done', false).order('created_at').limit(10)

// @mini-baas/js — options form (also fine)
const data = await client.from('todos').select({
  columns: '*', filters: { done: false }, order: 'created_at', limit: 10,
})
```

Filter/modifier parity on the fluent builder:
`eq · neq · gt · gte · lt · lte · like · ilike · is · in · or · order · limit ·
range · single · maybeSingle`. The generated PostgREST URL is byte-identical to
what `supabase-js` produces for the same filters.

Writes are the same names:

```ts
await client.from('todos').insert({ title: 'x' })
await client.from('todos').update({ done: true }, { filters: { id: 1 } })
await client.from('todos').delete({ filters: { id: 1 } })
```

Two response-shape differences to know:

- **No `{ data, error }` envelope.** Grobase methods **return data and throw**
  (`MiniBaasError`) on failure — idiomatic async/await. Wrap in `try/catch`
  instead of checking `error`. (A thin `{ data, error }` shim is a small adapter
  if you want zero call-site changes — see §9.)
- `.single()` / `.maybeSingle()` behave as in `supabase-js` (object vs `null`).

Postgres RPC is identical:

```ts
await client.rpc('my_function', { arg: 1 })   // POST /rest/v1/rpc/my_function
```

---

## 4. Auth (`.auth`)

Near-total parity — Grobase vendors GoTrue:

| supabase-js | @mini-baas/js | Status |
|---|---|---|
| `auth.signUp(...)` | `auth.signUp(...)` | ✅ |
| `auth.signInWithPassword(...)` | `auth.signInWithPassword(...)` (alias `signIn`) | ✅ |
| `auth.signInWithOAuth({ provider })` | `auth.signInWithOAuth({ provider, redirectTo })` → `{ url }` | ✅ returns the authorize URL to open, like supabase-js |
| `auth.signOut()` | `auth.signOut()` | ✅ |
| `auth.getUser()` | `auth.getUser()` (alias `user()`) | ✅ |
| `auth.updateUser(...)` | `auth.updateUser(...)` | ✅ |
| `auth.refreshSession()` | `auth.refreshSession()` | ✅ |
| `auth.resetPasswordForEmail(...)` | `auth.recover({ email })` | ✅ name differs |
| `auth.mfa.enroll/challenge/verify` | `auth.mfa.enroll/challenge/verify` | ✅ TOTP/phone |
| `auth.admin.createUser/...` | `auth.admin.createUser/...` (needs `serviceRoleKey`) | ✅ |
| `auth.onAuthStateChange(cb)` | — (poll `getSession()` / handle in app state) | ⚠ not a callback yet |

Session persistence is built in (`persistSession`, `storage`, `storageKey`
options) — same idea as supabase-js.

---

## 5. Storage (`.storage`)

```diff
- await supabase.storage.from('avatars').upload('me.png', file)
- await supabase.storage.from('avatars').download('me.png')
- await supabase.storage.from('avatars').createSignedUrl('me.png', 3600)
+ await client.storage.from('avatars').upload('me.png', file)
+ await client.storage.from('avatars').download('me.png')
+ await client.storage.from('avatars').createSignedUrl('me.png', 3600)
```

Parity: `from(bucket).upload/download/list/remove/createSignedUrl`, plus
`storage.listBuckets()` / `storage.createBucket(name)`.

Difference: **every key is auto-prefixed with the caller's user id
server-side** — owner isolation is enforced by the storage-router, not by a
client-side path convention. You don't pass `owner/` prefixes; you can't read
another user's objects. (Supabase relies on storage RLS policies you author;
Grobase enforces owner-scoping by default.) Image transforms are tracked in the
matrix as PARTIAL — check the row before depending on `?width=`.

---

## 6. Realtime (`.subscribe`)

Grobase realtime is CDC over WebSocket (Postgres triggers + `LISTEN/NOTIFY`,
Mongo change streams), exposed through `RealtimeClient`:

```ts
// supabase-js
supabase.channel('rt')
  .on('postgres_changes', { event: '*', schema: 'public', table: 'todos' }, cb)
  .subscribe()

// @mini-baas/js
import { RealtimeClient } from '@mini-baas/js'
const rt = new RealtimeClient(httpClientFromBaas)
const sub = await rt.subscribe({
  adapter: 'postgresql',
  channel: 'public.todos',
  filter: { /* server-side */ },
  onEvent: (e) => cb(e),   // e.event = insert|update|delete, e.row = the row
})
// later: await sub.unsubscribe()
```

Shape difference: one subscription = one topic (you pass `adapter` + `channel`),
events arrive as `{ topic, event, row, ts }`. Filters are evaluated server-side
in the Rust engine.

---

## 7. Edge functions

Both run Deno. Deploy/invoke through the SDK:

```ts
await client.functions.deploy({ name: 'hello', code: '…Deno handler…' })
const out = await client.functions.invoke('hello', { name: 'world' })
```

Supabase's `supabase functions deploy` CLI maps to the Grobase `baas` CLI
(`baas functions deploy <file>`), shipped as the SDK `bin`. DB-event triggers,
cron schedules, and per-function secrets are part of this release's Functions DX
track; check the Functions rows in
[`competitive-matrix.md`](competitive-matrix.md) for exact status before relying
on a specific trigger type.

---

## 8. The unique on-ramp: wrap your existing Postgres (`tenant_owned`)

Supabase requires your data to live **in** Supabase's Postgres. Grobase can put
the uniform API **in front of a database you already operate** — your RDS,
Cloud SQL, self-managed Postgres, even MySQL/Mongo — using the `tenant_owned`
isolation model. No migration, no row copy, no downtime.

Server-side (admin / `serviceRoleKey`), register the external database as a
mount:

```ts
const admin = createClient({ url: BAAS_URL, anonKey, serviceRoleKey })
await admin.admin.provision({
  /* declarative mount spec: engine + encrypted DSN + isolation: tenant_owned */
})
```

Then your app queries it through the same `/query/v1` uniform API (the
capability-typed `client.engine(...)` or `client.fromQuery(...)`), and the DSN
stays AES-256-GCM-encrypted in the adapter-registry. This lets you **adopt
Grobase incrementally** — front your real database first, move workloads later
(or never). See [`03-control-plane.md`](03-control-plane.md) for the
provisioning model and [`grobase-vs-supabase-offer.md`](grobase-vs-supabase-offer.md)
for the service-for-service comparison.

---

## 9. Optional: a `{ data, error }` compatibility shim

If you want to migrate without touching call sites that destructure
`{ data, error }`, wrap the throwing methods:

```ts
async function compat<T>(p: Promise<T>): Promise<{ data: T | null; error: Error | null }> {
  try { return { data: await p, error: null } }
  catch (error) { return { data: null, error: error as Error } }
}
// const { data, error } = await compat(client.from('todos').select())
```

---

## 10. Migration checklist

- [ ] Stand up Grobase (`make quickstart PACKAGE=pro` for realtime+storage, or a
      managed cloud project) — see [`QUICKSTART`](../mini-baas-infra/QUICKSTART.md).
- [ ] Recreate schema **or** register your existing DB as a `tenant_owned` mount (§8).
- [ ] Swap the dependency + `createClient` call (§2).
- [ ] Port RLS policies (they're the same Postgres RLS — copy them verbatim).
- [ ] Replace `{ data, error }` with `try/catch` or the shim (§3, §9).
- [ ] Re-create auth providers (OAuth client IDs/secrets) in GoTrue config.
- [ ] Re-point storage buckets; drop client-side owner prefixes (§5).
- [ ] Re-wire realtime subscriptions to `RealtimeClient.subscribe` (§6).
- [ ] Verify each feature you depend on is at parity in
      [`competitive-matrix.md`](competitive-matrix.md) before cutover.

> Differentiators you gain by moving: **multi-engine** (Postgres *and*
> MySQL/Mongo/Redis/MSSQL/SQLite behind one API), **bring-your-own-database**,
> **dense multi-tenancy** (thousands of tenants on shared infra), an **in-stack
> OWASP WAF**, and **single-binary editions** (binocle-one/nano) for the edge.
