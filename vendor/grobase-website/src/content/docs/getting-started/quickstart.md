---
title: Quickstart
description: Run Grobase locally, create a project, mint an API key, and make your first CRUD and realtime calls in a few minutes.
section: Getting started
order: 2
---

# Quickstart

This walkthrough takes you from nothing to a working backend: a running server, a
project, an API key, and your first read and write through the SDK. Every step is
the same whether you stay on the single 5 MB binary or grow to the platform later.

## Step 1: Run the server

The nano edition is a single static binary with no external dependencies — it
embeds its own datastore, so there is nothing else to install.

```
grobase serve --data ./grobase-data
```

The server starts on `http://localhost:8090`. Larger tiers run the same API from a
container image instead; the SDK and the calls below do not change.

## Step 2: Create a project and an API key

A project is an isolated namespace for your data. An API key is a
capability-scoped credential — it carries exactly the permissions you grant it and
nothing more.

```
grobase project create my-app
grobase key create --project my-app --scope read,write
```

Keep the printed key secret. Keys are high-entropy tokens verified with a fast
hash, so revoking and re-issuing one is instant.

## Step 3: Install the SDK

```
npm install @mini-baas/js
```

## Step 4: Read and write

The SDK talks to the same uniform API regardless of which engine backs your
project. Point it at your server and your key:

```
import { createClient } from '@mini-baas/js';

const db = createClient({
  url: 'http://localhost:8090',
  apiKey: process.env.GROBASE_KEY,
});

await db.from('notes').insert({ title: 'First note', body: 'Hello.' });
const recent = await db.from('notes').select().order('created_at', 'desc').limit(10);
```

Every write is stamped with the caller's owner identity, and every read is
owner-scoped on the server — so this code only ever sees the rows it created,
without you writing a single access-control rule.

## Step 5: Subscribe to changes

Realtime is built in, not a separate service. Subscribe to a table and you get a
live feed of inserts, updates and deletes as they happen:

```
db.from('notes').subscribe((change) => {
  console.log(change.type, change.record);
});
```

## Next steps

You now have the loop that every Grobase app is built on: a project, a scoped key,
and uniform CRUD plus realtime. Read [Core concepts](/docs/getting-started/concepts/)
to understand owner-scoping and engines, then pick a guide such as
[Database CRUD](/docs/guides/database-crud/) or
[Authentication](/docs/guides/authentication/).
