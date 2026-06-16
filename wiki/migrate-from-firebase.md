# Migrate from Firebase to Grobase

Firebase → Grobase is a **cross-paradigm** migration, not a drop-in. Firebase is
a document/realtime-first BaaS (Firestore, Realtime Database, Cloud Functions,
FCM); Grobase is relational-first with a uniform multi-engine API. So unlike the
[Supabase guide](migrate-from-supabase.md) — which is mostly a dependency swap —
this is a **design-pattern translation**. This document maps each Firebase
concept to its Grobase equivalent, calls out where the mental model changes, and
is honest about what has no equivalent yet.

> Read the status of every feature you depend on in
> [`competitive-matrix.md`](competitive-matrix.md) before committing. Push
> messaging (FCM) in particular has **no Grobase equivalent today** (it is also a
> Supabase gap) — see §7.

---

## 1. Concept map

| Firebase | Grobase | Migration shape |
|---|---|---|
| **Firestore** (document DB) | MongoDB mount (closest) **or** Postgres + JSONB | Document → Mongo collection is the lowest-friction path; relational gives you SQL + RLS. |
| **Realtime Database** (JSON tree, live) | Postgres/Mongo + realtime CDC (`/realtime/v1`) | Model state in tables/collections; subscribe to changes instead of reading a live tree. |
| **Firebase Auth** | GoTrue (`/auth/v1`) | Email/password, OAuth/OIDC, MFA. User export → GoTrue import. |
| **Cloud Functions** | Functions (Deno) (`/functions/v1`) | Rewrite handlers for the Deno runtime; HTTP-invoke + DB-event triggers + cron. |
| **Security Rules** | Postgres RLS **/** owner-scoping | Declarative `match`/`allow` rules → SQL `CREATE POLICY` (or default owner-scope on Mongo). |
| **Cloud Storage** | storage-router (`/storage/v1`, S3/MinIO) | `upload/download/list/createSignedUrl`; owner-scoped by default. |
| **Cloud Messaging (FCM)** | — (none yet) | No equivalent. See §7 for options. |
| **Remote Config / Analytics** | analytics service (events) / app config | Partial; analytics is event-track, not A/B Remote Config. |

---

## 2. Data: Firestore / RTDB → Grobase

**The core shift:** Firebase encourages denormalised document trees read live;
Grobase encourages either documents (Mongo) or normalised relations (Postgres)
read via queries + subscribed to via CDC.

Two target shapes:

- **Firestore → Mongo mount** (least rewrite). A Firestore collection becomes a
  Mongo collection; documents stay documents. Owner-scoping is automatic — the
  server stamps `owner_id` from the JWT and rejects cross-owner reads/writes, so
  you delete the per-document ownership checks you wrote as Security Rules.

  ```ts
  // Firestore: db.collection('orders').add({...})
  // Grobase (Mongo engine, uniform API):
  const mongo = client.engine('mongodb', dbId, 'orders')
  await mongo.insert({ total: 42 })          // owner_id injected server-side
  const mine = await mongo.list({ filter: { status: 'open' } })
  ```

- **Firestore/RTDB → Postgres** (more rewrite, more power). Model entities as
  tables; use JSONB columns for genuinely schemaless blobs. You gain SQL joins,
  aggregates, transactions, and full RLS. Query with the Supabase-shaped
  `client.from('orders')...` builder (see the [Supabase guide §3](migrate-from-supabase.md#3-database-queries-from)).

**Live data:** replace Firestore/RTDB `onSnapshot` listeners with a Grobase
realtime subscription:

```ts
// Firestore: onSnapshot(query, snap => …)
const sub = await new RealtimeClient(http).subscribe({
  adapter: 'mongodb',           // or 'postgresql'
  channel: 'orders',
  onEvent: (e) => render(e),    // insert | update | delete + the doc/row
})
```

Difference: Firebase pushes the **full result set** on every change; Grobase
pushes **the change event** (the changed row/document). You apply deltas to local
state rather than replacing the whole snapshot — usually a net win for bandwidth.

---

## 3. Auth: Firebase Auth → GoTrue

- Email/password, phone, and OAuth providers (Google, GitHub, Apple, …) all map
  to GoTrue providers — reconfigure the client IDs/secrets in GoTrue.
- MFA (TOTP) is supported (`client.auth.mfa.*`).
- **User migration:** export Firebase users (`firebase auth:export`) and import
  into GoTrue. Password hashes: Firebase uses scrypt with project-specific
  parameters — plan either a hash-import (if your GoTrue build supports the
  scheme) or a **lazy re-hash on next login** (prompt password reset for the
  rest). Custom claims → GoTrue `app_metadata` / `user_metadata`.

API shape is the same as the Supabase guide — `client.auth.signUp`,
`signInWithPassword`, `signInWithOAuth`, `mfa.enroll/challenge/verify`.

---

## 4. Security Rules → RLS / owner-scoping

Firestore Security Rules are a declarative DSL evaluated per request. Grobase has
two enforcement layers depending on the engine:

- **Mongo mounts:** owner-scoping is **automatic** — the server forces
  `owner_id = <jwt user>` on every read and write. Most `request.auth.uid ==
  resource.data.ownerId` rules simply disappear.
- **Postgres:** translate rules to RLS policies. Example:

  ```
  // Firestore
  match /orders/{id} {
    allow read, write: if request.auth.uid == resource.data.ownerId;
  }
  ```
  ```sql
  -- Grobase (Postgres RLS)
  ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
  CREATE POLICY owner_rw ON orders
    USING (owner_id = current_setting('app.current_tenant_id', true)::uuid)
    WITH CHECK (owner_id = current_setting('app.current_tenant_id', true)::uuid);
  ```

Role/claim-based rules (`request.auth.token.admin == true`) become RLS predicates
over the JWT claims surfaced as `current_setting(...)` GUCs. More expressive
rules (cross-document lookups) map to RLS subqueries or SQL functions.

---

## 5. Cloud Functions → Grobase Functions

- HTTP-triggered functions → deploy a Deno handler and invoke it
  (`client.functions.invoke(...)` or the `/functions/v1` route).
- Firestore-trigger functions (`onCreate`/`onUpdate`/`onDelete`) →
  **DB-event triggers** that invoke a function on a change (part of this
  release's Functions DX track — confirm the trigger type's row in the matrix).
- Scheduled functions (`pubsub.schedule`) → **cron schedules**.
- Rewrite note: Firebase Functions are Node by default; Grobase functions run on
  **Deno** — adjust imports (`npm:`/`https:` specifiers), no `firebase-admin`
  SDK (call the Grobase SDK or REST instead).

---

## 6. Storage

Firebase Cloud Storage → storage-router. `ref().put()` → `upload`,
`getDownloadURL()` → `createSignedUrl`, `listAll()` → `list`. Owner-scoping is
automatic (see the [Supabase guide §5](migrate-from-supabase.md#5-storage-storage)).
Storage Security Rules collapse into the default owner enforcement.

---

## 7. What has no equivalent yet (be honest)

- **Cloud Messaging / push (FCM):** no Grobase equivalent. If push is core to
  your app, keep FCM (or a provider like OneSignal) alongside Grobase for now, or
  track the messaging row in [`competitive-matrix.md`](competitive-matrix.md).
  *(Note: native push is also absent from Supabase — this is not a regression
  relative to either competitor.)*
- **Remote Config (A/B + live config):** the analytics service does event
  tracking, not Remote Config experiments. Use a feature-flag table you query at
  runtime as an interim.
- **ML Kit / Crashlytics / App Distribution / Hosting:** out of scope — these are
  Firebase platform extras, not BaaS-core, and aren't part of the Grobase offer.

---

## 8. Migration checklist

- [ ] Decide target engine per collection: **Mongo mount** (least rewrite) vs
      **Postgres** (SQL + RLS). Mixed is fine — Grobase is multi-engine.
- [ ] Stand up Grobase with realtime + storage (`make quickstart PACKAGE=pro`).
- [ ] Translate Security Rules → owner-scoping (Mongo) / RLS policies (Postgres) (§4).
- [ ] Export + import users into GoTrue; pick hash-import or lazy re-hash (§3).
- [ ] Migrate data (Firestore export → Mongo `mongoimport`, or ETL into Postgres).
- [ ] Rewrite Cloud Functions for Deno; re-wire triggers/schedules (§5).
- [ ] Replace `onSnapshot` with `RealtimeClient.subscribe` and apply deltas (§2).
- [ ] Keep FCM/push external until a Grobase equivalent ships (§7).
- [ ] Verify each depended-on feature's parity row before cutover.

> What you gain: one uniform API across **relational and document** engines,
> SQL where you want it, **dense multi-tenancy**, an **in-stack OWASP WAF**, and
> **single-binary editions** for the edge — without Firebase's vendor lock-in.
