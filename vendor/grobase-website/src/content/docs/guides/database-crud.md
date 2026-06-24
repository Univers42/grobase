---
title: Database CRUD
description: Read, write, filter, order, paginate and aggregate over any of the eight engines through one uniform query API.
section: Guides
order: 2
---

# Database CRUD

One query API spans every engine Grobase speaks. The calls below behave the same
whether the mount behind them is PostgreSQL, MySQL, MongoDB, MSSQL, SQLite, Redis,
DynamoDB, or an HTTP/JSON source.

## Insert

```
await db.from('tasks').insert({ title: 'Write docs', done: false });
```

The new row is stamped with your owner identity, so it belongs to you from the
moment it exists.

## Select, filter, order, paginate

```
const open = await db
  .from('tasks')
  .select('id, title, done')
  .eq('done', false)
  .order('created_at', 'desc')
  .limit(20)
  .offset(0);
```

Every read is owner-scoped on the server before any filter you add — you only ever
see your own rows, and your filters narrow that set further.

## Update and delete

```
await db.from('tasks').update({ done: true }).eq('id', taskId);
await db.from('tasks').delete().eq('id', taskId);
```

Updates and deletes are scoped the same way: you cannot modify a row you do not
own, even if you know its id.

## Aggregates

`count`, `sum`, `avg`, `min` and `max` with optional grouping run through the same
surface:

```
const byStatus = await db
  .from('tasks')
  .aggregate({ count: '*' })
  .groupBy('done');
```

## Atomic writes

When several writes must succeed or fail together, group them in a single
transaction so the data is never left half-written:

```
await db.txn((tx) => {
  tx.from('accounts').update({ balance: from }).eq('id', a);
  tx.from('accounts').update({ balance: to }).eq('id', b);
});
```

## Engine-agnostic by design

Because the API is uniform, changing the engine behind a mount — say, moving a
collection from SQLite to PostgreSQL as you scale — never touches this code. The
same is true moving from the nano binary up to the platform.

## Next steps

Stream these same tables live with [Realtime](/docs/guides/realtime/), or search
across them with [Search: full-text & vector](/docs/guides/search-fts-vector/).
