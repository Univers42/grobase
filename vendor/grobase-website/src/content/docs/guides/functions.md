---
title: Functions
description: Run server-side logic on a schedule, on a database change, or on demand — deployed and invoked through the same platform.
section: Guides
order: 5
---

# Functions

Functions let you run server-side logic without standing up another service. Use
them for the work that does not belong in the client: validating and enriching
data, reacting to changes, talking to a third party, running a nightly job.

## Deploy a function

```
grobase fn deploy welcome ./functions/welcome.js
```

Your function runs inside the platform with access to the same scoped data API,
under an identity you control.

## Invoke on demand

```
const result = await db.fn('welcome').invoke({ userId });
```

## Run on a database change (triggers)

Wire a function to fire whenever rows change — the realtime change feed becomes a
server-side hook:

```
grobase fn trigger welcome --on insert --table users
```

Each invocation receives the change that fired it, so you can act on the exact row
that was created, updated or deleted.

## Run on a schedule (cron)

```
grobase fn schedule digest --cron "0 8 * * *"
```

## Secrets

Functions read configuration and credentials from managed secrets, never from your
source. Set them out of band so keys never live in code or in the repo:

```
grobase fn secret set STRIPE_KEY --fn digest
```

## Next steps

Functions complete the loop with [Realtime](/docs/guides/realtime/) (the event
source) and [Database CRUD](/docs/guides/database-crud/) (the data they act on).
For production deployment, see [Configuration](/docs/self-hosting/configuration/).
