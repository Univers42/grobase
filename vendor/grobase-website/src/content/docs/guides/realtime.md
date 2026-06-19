---
title: Realtime
description: Subscribe to live inserts, updates and deletes via change-data-capture, with the same owner-scoping that protects your reads.
section: Guides
order: 3
---

# Realtime

Realtime is part of the platform, not a bolt-on service. Subscribe to a table and
Grobase streams a live feed of changes — inserts, updates and deletes — as they
land, fed by change-data-capture rather than polling.

## Subscribe to a table

```
const sub = db.from('messages').subscribe((change) => {
  // change.type is 'insert' | 'update' | 'delete'
  console.log(change.type, change.record);
});
```

You receive only changes to rows you are allowed to see — the same owner-scoping
that protects your reads protects your live feed. There is no way to subscribe
your way around access control.

## Filter a subscription

Narrow a subscription to the slice you care about so clients only wake for
relevant events:

```
db.from('messages')
  .eq('room_id', roomId)
  .subscribe((change) => render(change.record));
```

## Unsubscribe

Close a subscription when the view that needs it goes away:

```
sub.unsubscribe();
```

## How it works

The realtime plane consumes a change feed from the underlying engine and fans
each event out to the subscribers entitled to it. Owner-scoping is applied at
fan-out time, per subscriber, so isolation holds even when many tenants share
infrastructure.

## Next steps

Pair live data with durable files in [Storage](/docs/guides/storage/), or run
server-side logic on each change with [Functions](/docs/guides/functions/).
