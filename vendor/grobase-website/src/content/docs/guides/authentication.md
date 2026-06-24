---
title: Authentication
description: Sign-in, sessions, capability-scoped API keys, and how owner identity flows into every request so callers only see their own data.
section: Guides
order: 1
---

# Authentication

Grobase ships accounts and access control built in. Two credential types cover
almost everything you build: **user sessions** for people, and **API keys** for
services. Both resolve to an owner identity that the data plane enforces on every
request.

## User sign-in

Create an account and sign in with the SDK. A successful sign-in returns a session
the SDK stores and refreshes for you.

```
import { createClient } from '@mini-baas/js';

const auth = createClient({ url: process.env.GROBASE_URL });

await auth.signUp({ email: 'ada@example.com', password: 'a-strong-secret' });
const session = await auth.signIn({ email: 'ada@example.com', password: 'a-strong-secret' });
```

From then on, the client's reads and writes carry that user's identity, and the
server scopes them to that user's rows automatically.

## API keys

A key is a **capability mask** — it grants exactly the permissions you list and
nothing else. Issue narrow keys for narrow jobs:

```
grobase key create --scope read            # a read-only key for a dashboard
grobase key create --scope read,write      # a key for a worker that ingests data
```

Keys are high-entropy tokens verified with a fast hash (never a slow password
hash — they already have full entropy), so verification stays cheap even under
heavy load, and revocation is immediate.

## Owner identity is enforced server-side

Whichever credential a request uses, it resolves to an **owner principal**. The
data plane stamps that principal onto every write and filters every read by it.
You do not pass a user id into your queries and you cannot accidentally read
another owner's rows — the scope is applied on the server, per request, before the
query runs.

## Beyond owner-scoping

For finer rules — sharing, roles, team access — layer Row-Level-Security policies
on top. They are declarative conditions evaluated per request alongside the owner
scope. Start with owner-scoping (it is on by default) and add policies only where
you actually need shared or role-based access.

## Next steps

With identity in place, move on to [Database CRUD](/docs/guides/database-crud/) to
read and write owner-scoped data, or [Realtime](/docs/guides/realtime/) to stream
changes as they happen.
